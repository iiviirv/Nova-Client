import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/proxy_profile.dart';
import 'proxy_controller.dart';
import 'subscription.dart';
import 'singbox/proxy_node.dart';
import 'singbox/singbox_config.dart';

/// Drives the proxy on **desktop** (macOS, Windows, Linux) from pure Dart, no
/// native plugin required: it extracts the bundled sing-box binary, runs it as a
/// child process with a local `mixed` (SOCKS+HTTP) inbound, points the system
/// proxy at it, and reads sing-box's Clash API for live traffic. The same file
/// serves every desktop OS; only the system-proxy command differs per platform.
///
/// Android keeps its VpnService host and iOS its Network Extension; this is the
/// desktop equivalent of those hosts.
class DesktopProxyController extends ProxyController {
  DesktopProxyController({
    this.socksPort = 2080,
    this.clashPort = 9191,
    this.manageSystemProxy = true,
  });

  final int socksPort;
  final int clashPort;

  /// When true, point the OS proxy at the local core on connect (needs a one-off
  /// admin authorization on macOS). When false, the core still runs and the
  /// local SOCKS/HTTP proxy is usable, the user just sets it manually.
  final bool manageSystemProxy;

  ProxyConnectionState _state = ProxyConnectionState.disconnected;
  @override
  ProxyConnectionState get state => _state;

  TrafficStats _traffic = TrafficStats.zero;
  @override
  TrafficStats get traffic => _traffic;

  ProxyProfile? _active;
  @override
  ProxyProfile? get activeProfile => _active;

  String? _lastError;
  @override
  String? get lastError => _lastError;

  Process? _process;
  Timer? _trafficTimer;
  int _lastUp = 0;
  int _lastDown = 0;
  bool _systemProxyOn = false;

  @override
  void selectProfile(ProxyProfile? profile) {
    _active = profile;
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    if (_state.isActive || _state.isBusy) return;
    final profile = _active;
    if (profile == null) {
      _fail('Select a config first');
      return;
    }
    _setState(ProxyConnectionState.connecting);
    try {
      final String config = await _buildConfig(profile);
      final String binary = await _ensureBinary();
      final Directory dir = await getApplicationSupportDirectory();
      final File cfgFile = File('${dir.path}/nova-singbox.json');
      await cfgFile.writeAsString(config);

      _process = await Process.start(binary, <String>['run', '-c', cfgFile.path]);
      // Surface fatal core output for diagnostics.
      _process!.stderr.transform(utf8.decoder).listen((String line) {
        if (line.trim().isNotEmpty) debugPrint('[sing-box] $line');
      });
      unawaited(_process!.exitCode.then(_onProcessExit));

      if (!await _waitForCore()) {
        throw 'The core did not come up in time';
      }
      await _setSystemProxy(true);
      _startTrafficPolling();
      _setState(ProxyConnectionState.connected);
    } catch (e) {
      await _cleanup();
      _fail(e.toString());
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == ProxyConnectionState.disconnected) return;
    _setState(ProxyConnectionState.disconnecting);
    await _cleanup();
    _setState(ProxyConnectionState.disconnected);
  }

  // --- internals -----------------------------------------------------------

  /// Build the sing-box config for [profile] and swap its TUN inbound for a
  /// local `mixed` inbound plus a Clash API controller, so it runs unprivileged.
  Future<String> _buildConfig(ProxyProfile profile) async {
    final String trimmed = profile.uri.trim();
    final Map<String, dynamic> cfg;
    if (profile.kind == ProxyKind.singboxConfig || trimmed.startsWith('{')) {
      cfg = (jsonDecode(trimmed) as Map).cast<String, dynamic>();
    } else {
      // Resolves single links directly and subscriptions by fetching them, so a
      // subscription profile can connect instead of failing as an invalid link.
      // A subscription expands to its whole node list so the core auto-picks the
      // fastest via a urltest; a single link is just the one node.
      final List<ProxyNode> nodes = await resolveProfileNodes(profile);
      if (nodes.isEmpty) throw 'Unsupported or invalid profile link';
      final SingboxRouteOptions opts = routeOptions;
      cfg = nodes.length == 1
          ? SingboxConfig.buildMap(nodes.first, options: opts)
          : SingboxConfig.buildMultiMap(nodes, options: opts);
    }
    cfg['inbounds'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'mixed',
        'tag': 'in',
        'listen': '127.0.0.1',
        'listen_port': socksPort,
      },
    ];
    final Map<String, dynamic> experimental =
        (cfg['experimental'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    experimental['clash_api'] = <String, dynamic>{
      'external_controller': '127.0.0.1:$clashPort',
    };
    cfg['experimental'] = experimental;
    return const JsonEncoder.withIndent('  ').convert(cfg);
  }

  /// Extract the bundled core binary to a writable, executable path (cached).
  Future<String> _ensureBinary() async {
    final String asset = _assetName();
    final Directory dir = await getApplicationSupportDirectory();
    final String exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
    final File out = File('${dir.path}/$exe');
    final ByteData data = await rootBundle.load('assets/bin/$asset');
    final int wantLen = data.lengthInBytes;
    if (!out.existsSync() || out.lengthSync() != wantLen) {
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, wantLen),
        flush: true,
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['+x', out.path]);
      }
    }
    return out.path;
  }

  String _assetName() {
    final String arch = _arch();
    if (Platform.isMacOS) return 'sing-box-macos-$arch';
    if (Platform.isWindows) return 'sing-box-windows-$arch.exe';
    return 'sing-box-linux-$arch';
  }

  String _arch() {
    final String v = Platform.version.toLowerCase();
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    return 'amd64';
  }

  /// Poll the Clash API until the core is serving (or time out).
  Future<bool> _waitForCore() async {
    final Uri url = Uri.parse('http://127.0.0.1:$clashPort/version');
    for (int i = 0; i < 40; i++) {
      if (_process == null) return false;
      try {
        final r = await http.get(url).timeout(const Duration(milliseconds: 500));
        if (r.statusCode == 200) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  void _startTrafficPolling() {
    _lastUp = 0;
    _lastDown = 0;
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollTraffic());
  }

  Future<void> _pollTraffic() async {
    try {
      final r = await http
          .get(Uri.parse('http://127.0.0.1:$clashPort/connections'))
          .timeout(const Duration(seconds: 2));
      if (r.statusCode != 200) return;
      final Map<String, dynamic> m = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      final int up = (m['uploadTotal'] as num?)?.toInt() ?? 0;
      final int down = (m['downloadTotal'] as num?)?.toInt() ?? 0;
      final double upBps = (up - _lastUp).clamp(0, 1 << 62).toDouble();
      final double downBps = (down - _lastDown).clamp(0, 1 << 62).toDouble();
      _lastUp = up;
      _lastDown = down;
      _traffic = TrafficStats(
        uplinkBps: upBps,
        downlinkBps: downBps,
        uplinkTotal: up,
        downlinkTotal: down,
      );
      notifyListeners();
    } catch (_) {}
  }

  /// Point the OS at our local proxy (or clear it). macOS/Windows for now.
  Future<void> _setSystemProxy(bool on) async {
    if (on && !manageSystemProxy) return;
    if (Platform.isMacOS) {
      final List<String> services = await _macServices();
      final List<String> cmds = <String>[];
      for (final String s in services) {
        if (on) {
          cmds.add('networksetup -setsocksfirewallproxy "$s" 127.0.0.1 $socksPort');
          cmds.add('networksetup -setsocksfirewallproxystate "$s" on');
        } else {
          cmds.add('networksetup -setsocksfirewallproxystate "$s" off');
        }
      }
      if (cmds.isEmpty) return;
      // One authorization prompt covers the whole batch.
      final String script = cmds.join(' && ').replaceAll('"', '\\"');
      await Process.run('osascript', <String>[
        '-e',
        'do shell script "$script" with administrator privileges',
      ]);
      _systemProxyOn = on;
    } else if (Platform.isWindows) {
      const String key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      if (on) {
        await Process.run('reg', <String>['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
        await Process.run('reg', <String>['add', key, '/v', 'ProxyServer', '/d', 'socks=127.0.0.1:$socksPort', '/f']);
      } else {
        await Process.run('reg', <String>['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
      }
      _systemProxyOn = on;
    }
  }

  Future<List<String>> _macServices() async {
    try {
      final r = await Process.run('networksetup', <String>['-listallnetworkservices']);
      final List<String> lines = (r.stdout as String).split('\n');
      return lines
          .where((String l) => l.isNotEmpty && !l.startsWith('*') && !l.contains('asterisk'))
          .map((String l) => l.trim())
          .where((String l) => l == 'Wi-Fi' || l == 'Ethernet' || l.contains('Ethernet'))
          .toList();
    } catch (_) {
      return <String>['Wi-Fi'];
    }
  }

  Future<void> _onProcessExit(int code) async {
    if (_state == ProxyConnectionState.connected ||
        _state == ProxyConnectionState.connecting) {
      await _cleanup();
      _fail('The core stopped unexpectedly (exit $code)');
    }
  }

  Future<void> _cleanup() async {
    _trafficTimer?.cancel();
    _trafficTimer = null;
    if (_systemProxyOn) {
      await _setSystemProxy(false);
    }
    _process?.kill();
    _process = null;
    _traffic = TrafficStats.zero;
  }

  void _setState(ProxyConnectionState s) {
    _state = s;
    if (s != ProxyConnectionState.error) _lastError = null;
    notifyListeners();
  }

  void _fail(String message) {
    _lastError = message;
    _state = ProxyConnectionState.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
