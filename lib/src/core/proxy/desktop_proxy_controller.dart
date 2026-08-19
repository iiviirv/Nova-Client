import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../logging/nova_log.dart';
import '../models/proxy_profile.dart';
import 'core_features.dart';
import 'proxy_controller.dart';
import 'singbox_proxy_controller.dart' show isBlockedConnectionNoise;
import 'subscription.dart';
import 'singbox/proxy_node.dart';
import 'singbox/singbox_config.dart';
import 'xray/xray_config.dart';

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

  /// The local `mixed` inbound doubles as an HTTP proxy, so conn-info probes can
  /// reach the exit through it. In TUN mode everything is already tunneled (like
  /// mobile), so no explicit proxy is needed. Only advertised while connected.
  @override
  String? get proxyUri => (_state.isActive && !tunMode)
      ? 'PROXY 127.0.0.1:$socksPort'
      : null;

  Process? _process;
  Process? _elevated;
  File? _runFlag;

  /// The second core, Xray, for xhttp/SplitHTTP nodes sing-box cannot run. When
  /// the exit is xhttp, sing-box bridges its inbound to Xray's local SOCKS (same
  /// two-core path as mobile), and Xray does the xhttp. Only wired for the
  /// unprivileged system-proxy path for now; TUN mode would need Xray's dials
  /// route-excluded from sing-box's tunnel to avoid a loop.
  Process? _xrayProcess;
  String? _pendingXrayConfig;

  /// Stable node key -> the panel-given name, rebuilt on every connect, so the
  /// dashboard can say "Connected via" the server name (see [exitName]).
  Map<String, String> _keyToName = <String, String>{};

  @override
  String? exitName(String? key) => key == null ? null : _keyToName[key];
  static const int _xraySocksPort = XrayConfig.defaultSocksPort;

  /// Rolling tail of the core's stdout+stderr (last ~40 lines) so a startup
  /// failure can report the actual FATAL reason instead of a generic timeout.
  final List<String> _coreTail = <String>[];

  /// Full core output is teed here (app-support/nova-core.log) so a user can
  /// send it when a connection fails.
  IOSink? _coreLogSink;
  File? _coreLogFile;

  /// Completes when the core subprocess exits, so [_waitForCore] can bail the
  /// moment the process dies (a config/runtime FATAL) instead of polling the
  /// whole timeout.
  Completer<void>? _coreExited;
  int? _coreExitCode;

  Timer? _trafficTimer;
  int _lastUp = 0;
  int _lastDown = 0;
  bool _systemProxyOn = false;

  /// One-shot guard for the auto (subscription) self-heal, matching the mobile
  /// core: if a subscription tunnel comes up but no traffic flows (urltest landed
  /// on a dead exit), rebuild the core once so it re-picks. [_healing] keeps the
  /// heal's own reconnect from re-arming the guard so a dead sub can't loop.
  /// Only ever runs in proxy mode — a TUN rebuild would raise a second UAC prompt.
  bool _autoHealTried = false;
  bool _healing = false;

  /// Supplies whether to run a whole-device TUN (needs one admin/UAC approval)
  /// instead of a local inbound + system proxy. Wired from settings at startup;
  /// defaults to the unprivileged system-proxy path.
  bool Function()? tunModeProvider;
  bool get tunMode => tunModeProvider?.call() ?? false;

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
    // A fresh user-initiated connect re-arms the one-shot self-heal; the heal's
    // own reconnect keeps [_autoHealTried] set (via [_healing]) so it can't loop.
    if (!_healing) _autoHealTried = false;
    _setState(ProxyConnectionState.connecting);
    try {
      final String config = await _buildConfig(profile);
      final String binary = await _ensureBinary();
      // Ask the bundled core what it can run, the way the Android host asks
      // libbox, instead of assuming. The desktop cores now ship from the same
      // pinned source and patch as Android (tool/core/build-desktop.sh) with
      // WireGuard, AmneziaWG and NaiveProxy in them, but a swapped or stale
      // binary would silently undo that, and the symptom of handing such a core
      // an `awg` endpoint is a process that exits at startup with the user told
      // only that it "did not come up in time". A `check` on a tiny probe
      // document surfaces "<x> is not included in this build" in under a
      // second, and the answer is cached per binary.
      if (CoreFeatures.usesAwg(config) && !await _coreSupports(binary, 'awg')) {
        _fail("This build's VPN core has no AmneziaWG support, so an AmneziaWG "
            "server cannot be used here. Use one of the server's other "
            'protocols, or update Nova.');
        return;
      }
      if (CoreFeatures.usesNaive(config) &&
          !await _coreSupports(binary, 'naive')) {
        _fail("This build's VPN core has no NaiveProxy support, so a NaiveProxy "
            "server cannot be used here. Use one of the server's other "
            'protocols, or update Nova.');
        return;
      }
      final Directory dir = await getApplicationSupportDirectory();
      final File cfgFile = File('${dir.path}/nova-singbox.json');
      await cfgFile.writeAsString(config);

      // xhttp exit: start Xray first so its local SOCKS is up before sing-box
      // bridges to it. Works in both proxy and TUN mode; in TUN mode the loop is
      // avoided by routing the server IP direct in the bridge config (see
      // buildXraySocksBridgeMap's directServerIp).
      if (_pendingXrayConfig != null) {
        if (!await _startXray(dir, _pendingXrayConfig!)) return;
      }

      if (tunMode) {
        // Whole-device TUN: sing-box creates the utun/wintun device and routes
        // everything, so it must run elevated and no system proxy is set.
        await _startElevatedTun(binary, cfgFile);
        if (!await _waitForCore()) {
          throw await _tunFailureMessage();
        }
      } else {
        _coreTail.clear();
        _coreExitCode = null;
        _coreExited = Completer<void>();
        await _openCoreLog(cfgFile);

        // Kill any orphaned Nova core left holding the mixed/Clash ports before
        // we spawn a fresh one. If the app was force-quit (or crashed) while
        // connected, its child sing-box can outlive it and keep 127.0.0.1:2080
        // bound, so the next connect FATALs with "address already in use". Our
        // own [_process] is already gone by then, so [_cleanup] can't see it.
        await _killStaleCores(cfgFile.path);

        _process =
            await Process.start(binary, <String>['run', '-c', cfgFile.path],
                environment: _coreEnv);
        // Capture BOTH streams into the rolling tail and the log file, so a
        // startup FATAL is visible in release builds (not just debugPrint).
        _pipeCore(_process!.stdout, 'out');
        _pipeCore(_process!.stderr, 'err');
        unawaited(_process!.exitCode.then((int code) {
          _coreExitCode = code;
          if (!(_coreExited?.isCompleted ?? true)) _coreExited!.complete();
          _onProcessExit(code);
        }));

        if (!await _waitForCore()) {
          // If the core exited, its final stderr (the FATAL reason) can still be
          // in flight on the stream after exitCode fires; let it drain first.
          if (_coreExitCode != null) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          final String reason = _coreTailText();
          final String logPath = _coreLogFile?.path ?? '';
          final String suffix = logPath.isEmpty ? '' : ' Log: $logPath';
          // A port-already-bound FATAL is the one desktop failure a user can act
          // on directly. We already kill our own orphaned core before starting,
          // so if the port is STILL taken it's another program (or a core we
          // couldn't reach). Surface a plain instruction instead of the raw
          // sing-box deprecation-plus-FATAL wall of text.
          final String low = reason.toLowerCase();
          if (low.contains('address already in use') ||
              low.contains('only one usage of each socket address')) {
            throw 'Port $socksPort is already in use by another program. '
                'Close whatever is using it (or restart your computer), then '
                'connect again.$suffix';
          }
          if (_coreExitCode != null) {
            // The process FATAL-exited before the API came up: report the exit
            // code and the last core output (the real reason).
            throw 'Core failed to start (exit $_coreExitCode).'
                '${reason.isEmpty ? '' : ' $reason.'}$suffix';
          }
          // Still running but the Clash API never answered within the budget.
          throw 'Core failed to start: timed out waiting for the control API.'
              '${reason.isEmpty ? '' : ' Last output: $reason.'}$suffix';
        }
        await _setSystemProxy(true);
      }
      _startTrafficPolling();
      _setState(ProxyConnectionState.connected);
      // Auto (subscription) post-connect health check, proxy mode only (a TUN
      // rebuild would re-prompt for admin). Mirrors the mobile core.
      if (!_healing && !tunMode && (_active?.isSubscription ?? false)) {
        unawaited(_verifyAutoConnectivity());
      }
    } catch (e) {
      await _cleanup();
      _fail(e.toString());
    }
  }

  /// After a subscription tunnel comes up in proxy mode, confirm traffic really
  /// flows through the local exit. urltest can lead with a dead node, leaving the
  /// orb "connected" while nothing loads; probe for ~18s (letting urltest settle)
  /// and, if still nothing, rebuild the core ONCE so it re-picks. Guarded against
  /// looping; the dashboard's honest "Verifying…" label covers the wait.
  Future<void> _verifyAutoConnectivity() async {
    final ProxyProfile? profile = _active;
    if (profile == null || !profile.isSubscription) return;
    for (int attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (_state != ProxyConnectionState.connected || _active?.id != profile.id) {
        return;
      }
      if (await _probeInternet()) return; // traffic flows — done
    }
    if (_autoHealTried || tunMode) return;
    _autoHealTried = true;
    _healing = true;
    try {
      // Spend the one rebuild on the SNI-block bypass when the subscription has
      // clean-IP fronted nodes and none carried traffic (the mobile controller
      // does the same; see its _escalateToBypass). Persisted, and announced.
      if (!profile.hardenTls) {
        List<ProxyNode> nodes = const <ProxyNode>[];
        try {
          nodes = await resolveProfileNodes(profile, fetch: subFetcher);
        } catch (_) {/* fall through to a plain rebuild */}
        if (nodes.any((ProxyNode n) => n.isCleanIpFronted)) {
          final ProxyProfile hardened = profile.copyWith(hardenTls: true);
          _active = hardened;
          await persistProfile?.call(hardened);
          NovaLog.instance.write(
            'Turning on the SNI-block bypass for "${profile.name}" (no traffic '
            'on any server).',
            level: NovaLogLevel.warn,
          );
          notice.value = ProxyNotice.sniBypassOn;
        }
      }
      await reconnect();
    } finally {
      _healing = false;
    }
  }

  /// A tiny generate_204 request through the local exit: its completion is the
  /// "traffic is getting through" signal. Routes via the local mixed inbound
  /// (proxy mode) exactly like the conn-info probe. Non-Cloudflare endpoints on
  /// purpose (a Nova worker can't relay to Cloudflare's own hosts).
  Future<bool> _probeInternet() async {
    const List<String> urls = <String>[
      'https://www.gstatic.com/generate_204',
      'https://connectivitycheck.gstatic.com/generate_204',
      'https://www.google.com/generate_204',
    ];
    for (int attempt = 0; attempt < 2; attempt++) {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      client.findProxy = (_) => proxyUri ?? 'DIRECT';
      try {
        for (final String url in urls) {
          try {
            final HttpClientRequest req = await client.getUrl(Uri.parse(url));
            req.followRedirects = false;
            final HttpClientResponse resp =
                await req.close().timeout(const Duration(seconds: 5));
            await resp.drain<void>();
            if (resp.statusCode >= 200 && resp.statusCode < 400) return true;
          } catch (_) {
            // Try the next endpoint.
          }
        }
      } finally {
        client.close(force: true);
      }
    }
    return false;
  }

  @override
  Future<void> disconnect() async {
    if (_state == ProxyConnectionState.disconnected) return;
    // A real user disconnect clears the heal guard so the next session can heal
    // again; the heal's own reconnect (which disconnects first) must not.
    if (!_healing) _autoHealTried = false;
    _setState(ProxyConnectionState.disconnecting);
    await _cleanup();
    _setState(ProxyConnectionState.disconnected);
  }

  // --- internals -----------------------------------------------------------

  /// Build the sing-box config for [profile] and swap its TUN inbound for a
  /// local `mixed` inbound plus a Clash API controller, so it runs unprivileged.
  /// Test seam: the config this controller would run for [profile], without
  /// starting anything. Lets the pin/name behaviour be asserted directly.
  @visibleForTesting
  Future<String> buildConfigForTest(ProxyProfile profile) =>
      _buildConfig(profile, extractRuleSets: false);

  Future<String> _buildConfig(ProxyProfile profile,
      {bool extractRuleSets = true}) async {
    final String trimmed = profile.uri.trim();
    final Map<String, dynamic> cfg;
    if (profile.kind == ProxyKind.singboxConfig || trimmed.startsWith('{')) {
      cfg = (jsonDecode(trimmed) as Map).cast<String, dynamic>();
    } else {
      // Resolves single links directly and subscriptions by fetching them, so a
      // subscription profile can connect instead of failing as an invalid link.
      // A subscription expands to its whole node list so the core auto-picks the
      // fastest via a urltest; a single link is just the one node.
      List<ProxyNode> nodes = await resolveProfileNodes(profile, fetch: subFetcher);
      if (nodes.isEmpty) throw emptyResolveMessage(profile);
      // Remember each node's panel-given name by its stable key so the dashboard
      // can say "Connected via <name>". Without this desktop showed a bare
      // ip:port where mobile showed the server's name.
      _keyToName = <String, String>{
        for (final ProxyNode n in nodes) proxyNodeKey(n): n.tag,
      };
      // Honour a manually pinned exit. Desktop used to ignore the pin entirely
      // and always hand the whole list to the urltest, so picking Germany still
      // exited through whichever node was fastest (a user reported Holland).
      // Match by stable key first, then by the pinned name, which survives a
      // panel rotating its clean IP (that changes the key but not the name).
      final String? pin = profile.pinnedNode;
      if (pin != null) {
        ProxyNode? chosen;
        for (final ProxyNode n in nodes) {
          if (proxyNodeMatchesKey(n, pin)) {
            chosen = n;
            break;
          }
        }
        final String? pinName = profile.pinnedName;
        if (chosen == null && (pinName ?? '').isNotEmpty) {
          for (final ProxyNode n in nodes) {
            if (n.tag == pinName) {
              chosen = n;
              NovaLog.instance.write(
                  'Your chosen server\'s address changed; matched it by name '
                  '("$pinName") so you stay on the same one.');
              break;
            }
          }
        }
        if (chosen != null) {
          nodes = <ProxyNode>[chosen];
          NovaLog.instance.write(
              'Using your chosen server ${chosen.server}:${chosen.port} '
              '(${chosen.protocol.label})');
        } else {
          // Connecting through a different server than the one the list shows
          // as selected must never be silent.
          NovaLog.instance.write(
            'The server you chose is no longer in this subscription; '
            'auto-selecting instead',
            level: NovaLogLevel.warn,
          );
          notice.value = ProxyNotice.pinnedExitGone;
        }
      }
      // Desktop uses BUNDLED local rule-sets. A remote rule-set that can't be
      // downloaded makes sing-box FATAL on startup ("initialize rule-set: i/o
      // timeout"), which is exactly what happens in Iran where the CDN
      // (raw.githubusercontent.com) is filtered, surfacing as "the core did not
      // come up in time". Shipping the .srs on disk removes that startup fetch.
      //
      // tlsFragment stays ON. The OLD bundled desktop core rejected the outbound
      // `tls.fragment` key and FATALed with "unknown field \"fragment\"" (the
      // "core did not come up in time" report); we now ship the sing-box 1.13.13
      // core (matching Android), which accepts it (verified: it comes up in ~1s
      // with fragment on). Keeping fragmentation matters in Iran, without it the
      // SNI is exposed in one packet and DPI can block the tunnel to the worker.
      // If a future desktop core ever lacks the key, add `tlsFragment: false`.
      final SingboxRouteOptions opts = routeOptions.copyWith(
        localRuleSets: true,
        // The SNI-block bypass, per profile (see the mobile controller).
        hardenTls: profile.hardenTls,
        // Windows: keep the bypass's TLS-record split but drop its TCP-segment
        // split, whose ACK-wait an unelevated Windows core cannot drive (see
        // SingboxRouteOptions.hardenPacketFragment). macOS/Linux keep both.
        hardenPacketFragment: !Platform.isWindows,
        // macOS will only accept a TUN named utun<N>; a custom name fails the
        // connect outright with "configure tun interface: bad tun name", which
        // is what the hardcoded "nova-tun" did to every Mac. Leave it unset
        // there and let the core pick a utun. Windows (wintun) and Linux take
        // an arbitrary name, and a recognisable one is worth having.
        tunInterfaceName: Platform.isMacOS ? null : 'nova-tun',
      );
      // xhttp is an Xray-only transport. When the exit is a single/pinned xhttp
      // node, hand the transport to Xray: sing-box gets a bridge config (its
      // inbound forwarded to Xray's local SOCKS) and Xray runs the real xhttp.
      // Same two-core path as mobile; the server host is resolved to an IP first
      // (Xray can't resolve it before the tunnel is up). The pool case (xhttp
      // mixed with other nodes) is a follow-up.
      _pendingXrayConfig = null;
      if (nodes.length == 1 && nodes.first.network == 'xhttp') {
        final ProxyNode x = await _resolveXhttpServer(nodes.first);
        _pendingXrayConfig = XrayConfig.build(x, socksPort: _xraySocksPort);
        // Pass the resolved server IP so the sing-box side routes it direct. In
        // TUN mode this is what stops Xray's own dial from looping back through
        // the tunnel; in proxy mode it's harmless (the server IP is the tunnel
        // endpoint, which belongs direct anyway).
        final String? serverIp =
            InternetAddress.tryParse(x.server) != null ? x.server : null;
        cfg = SingboxConfig.buildXraySocksBridgeMap(_xraySocksPort,
            options: opts, directServerIp: serverIp);
      } else {
        cfg = nodes.length == 1
            ? SingboxConfig.buildMap(nodes.first, options: opts)
            : SingboxConfig.buildMultiMap(nodes, options: opts);
      }
    }
    // System-proxy mode swaps the builder's TUN inbound for a local `mixed`
    // (SOCKS+HTTP) inbound so the core runs unprivileged. TUN mode keeps the
    // builder's `tun` inbound (auto_route) untouched so sing-box routes the
    // whole device once it is running elevated.
    if (!tunMode) {
      cfg['inbounds'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'mixed',
          'tag': 'in',
          'listen': '127.0.0.1',
          'listen_port': socksPort,
        },
      ];
    }
    final Map<String, dynamic> experimental =
        (cfg['experimental'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    experimental['clash_api'] = <String, dynamic>{
      'external_controller': '127.0.0.1:$clashPort',
    };
    cfg['experimental'] = experimental;
    // Point the config's local rule-set paths (the __NOVA_BASE__ token the
    // builder emits) at the extracted .srs directory on disk.
    // Tests skip the on-disk extraction (it needs a real platform for
    // path_provider) and keep the placeholder token in the JSON.
    final String base =
        extractRuleSets ? await _extractRuleSets() : SingboxConfig.ruleSetBaseToken;
    return const JsonEncoder.withIndent('  ')
        .convert(cfg)
        .replaceAll(SingboxConfig.ruleSetBaseToken, base);
  }

  /// Writes the bundled `.srs` rule-sets next to the core (once) and returns
  /// their directory. Forward slashes so the path is valid inside the JSON on
  /// Windows too (sing-box/Go accepts them on every platform).
  Future<String> _extractRuleSets() async {
    final Directory dir = await getApplicationSupportDirectory();
    for (final String file in <String>[
      SingboxConfig.kGeositeIrFile,
      SingboxConfig.kGeositeAdsFile,
    ]) {
      final File out = File('${dir.path}/$file');
      final ByteData data = await rootBundle.load('assets/rulesets/$file');
      final int len = data.lengthInBytes;
      if (!out.existsSync() || out.lengthSync() != len) {
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, len),
          flush: true,
        );
      }
    }
    return dir.path.replaceAll(r'\', '/');
  }

  /// Environment the core process runs with.
  ///
  /// The desktop core is the sing-box CLI, and unlike libbox on the phones the
  /// CLI enforces deprecations: on 1.13 it refuses to start on the legacy DNS
  /// server format the app still emits ("to continuing using this feature, set
  /// environment variable ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true"). The
  /// phones only get a warning for the same document, which is why this never
  /// showed up there. The proper fix is migrating `dns.servers` to the 1.12
  /// typed format for every platform, and that has to happen before a 1.14
  /// core, which removes the legacy form outright. Until then this keeps the
  /// desktop core starting.
  static const Map<String, String> _coreEnv = <String, String>{
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
  };

  /// Copy the bundled core binary to a writable, executable path (cached).
  ///
  /// The core is shipped next to the app executable (see [_bundledBinary]), not
  /// inside Flutter assets, so it isn't dead weight in the mobile builds. We copy
  /// it into the app-support dir and run it from there (a stable, writable path,
  /// and it keeps the app bundle read-only).
  Future<String> _ensureBinary() async {
    final File src = _bundledBinary();
    if (!src.existsSync()) {
      throw 'Bundled sing-box core not found at ${src.path}';
    }
    final Directory dir = await getApplicationSupportDirectory();
    final String exe = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
    final File out = File('${dir.path}/$exe');
    if (!out.existsSync() || out.lengthSync() != src.lengthSync()) {
      await src.copy(out.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['+x', out.path]);
      }
    }
    if (Platform.isWindows) {
      // TUN (full-device) mode on Windows needs wintun.dll beside the core, or
      // sing-box fails to create the tunnel. Ship it next to the exe (the CI
      // packages it) and mirror it into the run dir. Proxy mode doesn't use it,
      // so a missing dll only affects TUN mode.
      await _ensureWintun(dir);
      // NaiveProxy on Windows: the core is built with purego and loads
      // Chromium's cronet from libcronet.dll in its own directory (see
      // tool/core/build-desktop.sh). Lazily, so a user who never opens a Naive
      // server never touches it; but when they do, it has to be next to the exe.
      await _ensureSideDll(dir, 'libcronet.dll');
    }
    return out.path;
  }

  /// Copies the bundled `wintun.dll` next to the running core (Windows only).
  /// Best-effort: if the dll isn't found (e.g. running from source without it),
  /// proxy mode still works and TUN mode surfaces its own error.
  Future<void> _ensureWintun(Directory dir) async {
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final File src = <File>[
      File('${exeDir.path}\\wintun.dll'),
      File('assets/bin/wintun.dll'),
    ].firstWhere((File f) => f.existsSync(),
        orElse: () => File('${exeDir.path}\\wintun.dll'));
    if (!src.existsSync()) return;
    final File out = File('${dir.path}/wintun.dll');
    if (!out.existsSync() || out.lengthSync() != src.lengthSync()) {
      await src.copy(out.path);
    }
  }

  /// Mirror a DLL that ships beside the core into the run directory, so the
  /// core finds it in its own directory at load time. No-op when it was not
  /// shipped (an older bundle), which just leaves the matching feature off.
  Future<void> _ensureSideDll(Directory dir, String name) async {
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final File src = <File>[
      File('${exeDir.path}\\$name'),
      File('assets/bin/$name'),
    ].firstWhere((File f) => f.existsSync(),
        orElse: () => File('${exeDir.path}\\$name'));
    if (!src.existsSync()) return;
    final File out = File('${dir.path}/$name');
    if (!out.existsSync() || out.lengthSync() != src.lengthSync()) {
      await src.copy(out.path);
    }
  }

  /// What the staged core said it can run, keyed by `binary path|type`, so
  /// the probe runs once per binary and type for the life of the process.
  final Map<String, bool> _coreSupportCache = <String, bool>{};

  /// True when the bundled core can build a [type] (`awg` endpoint or `naive`
  /// outbound), measured by running `check` on a minimal document. Unreadable
  /// answers (the binary would not run at all) count as supported: this gate is
  /// for naming a missing protocol clearly, not for blocking a connect on a
  /// probe failure the real start would report anyway.
  Future<bool> _coreSupports(String binary, String type) async {
    final String key = '$binary|$type';
    final bool? cached = _coreSupportCache[key];
    if (cached != null) return cached;
    final Directory dir = await getApplicationSupportDirectory();
    final File probe = File('${dir.path}/nova-probe-$type.json');
    // Loopback peers and throwaway keys: nothing here is dialed by `check`.
    final String doc = type == 'awg'
        ? '{"log":{"level":"error"},"endpoints":[{"type":"awg","tag":"p",'
            '"address":["10.9.0.2/32"],'
            '"private_key":"yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=",'
            '"peers":[{"address":"127.0.0.1","port":1,'
            '"public_key":"xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=",'
            '"allowed_ips":["0.0.0.0/0"]}],'
            '"jc":4,"jmin":40,"jmax":70,"s1":0,"s2":0,"h1":1,"h2":2,"h3":3,"h4":4}]}'
        : '{"log":{"level":"error"},"outbounds":[{"type":"naive","tag":"p",'
            '"server":"127.0.0.1","server_port":1,"username":"u","password":"p",'
            '"tls":{"enabled":true,"server_name":"example.invalid"}}]}';
    bool ok = true;
    try {
      await probe.writeAsString(doc);
      final ProcessResult r = await Process.run(
        binary,
        <String>['check', '-c', probe.path],
        environment: _coreEnv,
      ).timeout(const Duration(seconds: 8));
      final String out = '${r.stdout}\n${r.stderr}'.toLowerCase();
      if (out.contains('not included in this build') ||
          out.contains('library not found')) {
        ok = false;
      }
    } catch (_) {
      ok = true;
    } finally {
      try {
        if (probe.existsSync()) probe.deleteSync();
      } catch (_) {/* best effort */}
    }
    _coreSupportCache[key] = ok;
    NovaLog.instance.write('Core capability: $type ${ok ? 'yes' : 'NO'}');
    return ok;
  }

  /// Locates the core binary shipped alongside the app executable:
  /// macOS `Nova.app/Contents/Resources/`, Windows next to `nova_client.exe`.
  /// Falls back to the repo `assets/bin/` path when running from source
  /// (`flutter run`), where the executable lives in the build tree.
  File _bundledBinary() {
    final String name = _assetName();
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // .../Contents/MacOS/<exe> -> .../Contents/Resources/<name>
      final File f = File('${exeDir.parent.path}/Resources/$name');
      if (f.existsSync()) return f;
    } else if (Platform.isWindows) {
      final File f = File('${exeDir.path}\\$name');
      if (f.existsSync()) return f;
    }
    return File('assets/bin/$name');
  }

  String _assetName() {
    final String arch = _arch();
    if (Platform.isMacOS) return 'sing-box-macos-$arch';
    if (Platform.isWindows) return 'sing-box-windows-$arch.exe';
    return 'sing-box-linux-$arch';
  }

  // ---- second core: Xray, for xhttp exits ----

  String _xrayAssetName() {
    final String arch = _arch();
    if (Platform.isMacOS) return 'xray-macos-$arch';
    if (Platform.isWindows) return 'xray-windows-$arch.exe';
    return 'xray-linux-$arch';
  }

  /// The bundled Xray binary, found the same way as the sing-box one (macOS
  /// arm64, Windows amd64, Linux amd64 all ship). A target with no binary returns
  /// a non-existent path, which [_startXray] turns into a clear "no Xray core"
  /// message rather than a crash.
  File _bundledXrayBinary() {
    final String name = _xrayAssetName();
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      final File f = File('${exeDir.parent.path}/Resources/$name');
      if (f.existsSync()) return f;
    } else if (Platform.isWindows) {
      final File f = File('${exeDir.path}\\$name');
      if (f.existsSync()) return f;
    }
    return File('assets/bin/$name');
  }

  /// Stages the Xray binary into app-support (chmod +x on POSIX) and returns its
  /// path, or null when this build carries no Xray core for the platform.
  Future<String?> _ensureXrayBinary() async {
    final File src = _bundledXrayBinary();
    if (!src.existsSync()) return null;
    final Directory dir = await getApplicationSupportDirectory();
    final String exe = Platform.isWindows ? 'xray.exe' : 'xray';
    final File out = File('${dir.path}/$exe');
    if (!out.existsSync() || out.lengthSync() != src.lengthSync()) {
      await src.copy(out.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['+x', out.path]);
      }
    }
    return out.path;
  }

  /// Starts Xray with [xrayJson] so its local SOCKS is up before sing-box bridges
  /// to it. Returns false (and fails the connect) when the core is missing.
  Future<bool> _startXray(Directory dir, String xrayJson) async {
    final String? bin = await _ensureXrayBinary();
    if (bin == null) {
      _fail('This build has no Xray core, so xhttp servers cannot run on '
          '${Platform.operatingSystem} yet.');
      return false;
    }
    final File cfg = File('${dir.path}/nova-xray.json');
    await cfg.writeAsString(xrayJson);
    _xrayProcess = await Process.start(
      bin,
      <String>['run', '-c', cfg.path],
      environment: _coreEnv,
    );
    _pipeCore(_xrayProcess!.stdout, 'xray');
    _pipeCore(_xrayProcess!.stderr, 'xray');
    // Give Xray a moment to bind its SOCKS inbound before sing-box dials it. A
    // dead process here means a bad config, surfaced by the sing-box side failing
    // to reach the bridge right after.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return true;
  }

  void _stopXray() {
    _xrayProcess?.kill();
    _xrayProcess = null;
    _pendingXrayConfig = null;
  }

  /// An xhttp node with its server host resolved to an IPv4 address (Xray needs a
  /// numeric server before the tunnel is up; the SNI/Host stay the domain).
  /// Best-effort: an unresolvable host passes through unchanged.
  Future<ProxyNode> _resolveXhttpServer(ProxyNode n) async {
    if (InternetAddress.tryParse(n.server) != null) return n;
    try {
      final List<InternetAddress> a = await InternetAddress
          .lookup(n.server, type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 4));
      if (a.isNotEmpty) return n.copyWith(server: a.first.address);
    } catch (_) {/* fall through with the domain */}
    return n;
  }

  String _arch() {
    final String v = Platform.version.toLowerCase();
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    return 'amd64';
  }

  /// Poll the Clash API until the core is serving (or time out).
  ///
  /// Budget is ~60s (80 iterations of up to ~750ms): Windows Defender can delay
  /// the first run of a freshly-copied, unsigned exe by a noticeable amount.
  /// Bails immediately if the subprocess exits (a config/runtime FATAL), so a
  /// dead core is reported at once instead of after the full timeout.
  Future<bool> _waitForCore() async {
    final Uri url = Uri.parse('http://127.0.0.1:$clashPort/version');
    for (int i = 0; i < 80; i++) {
      // Non-TUN (proxy) mode runs the core as our own child in [_process], so a
      // null reference means the start was aborted — bail. TUN mode has NO
      // [_process]: the core runs inside the elevated helper, and its Clash API
      // is the only handle we have. Guarding on [_process] there made every
      // full-device connect return false on the first iteration and report
      // "admin approval required" even after the user approved UAC and the
      // tunnel actually came up. So only apply that guard in proxy mode.
      if (!tunMode && _process == null) return false;
      // [_coreExited] tracks our own child (proxy mode). In TUN mode there is no
      // child and this completer may be left completed from a prior proxy
      // session, so only consult it in proxy mode.
      if (!tunMode && (_coreExited?.isCompleted ?? false)) return false;
      try {
        final r = await http.get(url).timeout(const Duration(milliseconds: 500));
        if (r.statusCode == 200) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Builds the message shown when full-device (TUN) mode fails to come up.
  /// The core runs elevated and logs to nova-tun.log (not our stdout tail), so we
  /// read that log's last lines for the real reason and distinguish the two
  /// common causes: the UAC/admin prompt was dismissed (no log written), or the
  /// core started but failed (a FATAL line in the log, e.g. missing wintun.dll).
  Future<String> _tunFailureMessage() async {
    String reason = '';
    String logPath = '';
    try {
      final Directory dir = await getApplicationSupportDirectory();
      final File log = File('${dir.path}/nova-tun.log');
      logPath = log.path;
      if (log.existsSync()) {
        final List<String> lines = (await log.readAsString())
            .split('\n')
            .map((String l) => l.replaceAll(RegExp('\\x1B\\[[0-9;]*m'), '').trim())
            .where((String l) => l.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          reason = lines.sublist(lines.length > 3 ? lines.length - 3 : 0).join(' | ');
        }
      }
    } catch (_) {
      // Best-effort; fall back to the generic guidance below.
    }
    if (reason.isEmpty) {
      // No log means the elevated core never ran — almost always a dismissed
      // Windows UAC (or macOS admin) prompt.
      return 'The tunnel did not come up. Full-device mode needs the admin '
          '(UAC) prompt approved so it can create the network adapter. Approve '
          'it and try again, or turn off full-device mode in Settings to use '
          'proxy mode (no admin needed).';
    }
    // The core ran but failed: surface its actual reason and the log path.
    return 'Full-device mode failed to start: $reason. Log: $logPath. You can '
        'turn off full-device mode in Settings to use proxy mode instead.';
  }

  /// Open (truncate) the tee log and record which config the core is running.
  Future<void> _openCoreLog(File cfgFile) async {
    try {
      final Directory dir = await getApplicationSupportDirectory();
      _coreLogFile = File('${dir.path}/nova-core.log');
      _coreLogSink = _coreLogFile!.openWrite(mode: FileMode.write);
      _coreLogSink!
        ..writeln('[nova] core start ${DateTime.now().toIso8601String()}')
        ..writeln('[nova] config ${cfgFile.path}');
    } catch (_) {
      _coreLogSink = null;
    }
  }

  /// Tee a core output stream to the rolling tail, the log file, and debugPrint.
  /// sing-box writes its level as a word in the line; the desktop core is a
  /// process rather than libbox, so there is no numeric level to read.
  NovaLogLevel _coreLineLevel(String line) {
    final String l = line.toUpperCase();
    if (l.contains('FATAL') || l.contains('ERROR')) return NovaLogLevel.error;
    if (l.contains('WARN')) return NovaLogLevel.warn;
    if (l.contains('DEBUG') || l.contains('TRACE')) return NovaLogLevel.debug;
    return NovaLogLevel.info;
  }

  void _pipeCore(Stream<List<int>> stream, String label) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String raw) {
      // sing-box colourizes levels with ANSI escapes; strip them so the message
      // and log stay readable.
      final String line =
          raw.replaceAll(RegExp('\\x1B\\[[0-9;]*m'), '').trim();
      if (line.isEmpty) return;
      debugPrint('[sing-box:$label] $line');
      // Feed the in-app log too, so the desktop builds have the same Settings ->
      // Logs view as mobile instead of only a file on disk. The by-design `block`
      // outbound rejections (QUIC on a TCP-only exit, ad/geo blocks) are filtered
      // from the quiet log exactly like mobile; the on-disk core log below still
      // keeps every line.
      if (routeOptions.verboseCoreLog || !isBlockedConnectionNoise(line)) {
        NovaLog.instance.writeCore(line, level: _coreLineLevel(line));
      }
      _coreTail.add(line);
      if (_coreTail.length > 40) _coreTail.removeAt(0);
      try {
        _coreLogSink?.writeln('[$label] $line');
      } catch (_) {}
    });
  }

  /// The last few core lines, collapsed to one line for an error banner.
  String _coreTailText({int lines = 3}) {
    if (_coreTail.isEmpty) return '';
    final int start = _coreTail.length > lines ? _coreTail.length - lines : 0;
    return _coreTail.sublist(start).join(' | ');
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

  /// Launch the core elevated so its `tun` inbound can create the system TUN
  /// device and route the whole machine.
  ///
  /// Both platforms use the same single-prompt trick: the elevated shell starts
  /// the core, then spins watching a plain "run flag" file the app owns. To stop
  /// (in [_cleanup]) the app just deletes that flag — the still-elevated loop
  /// then kills the core and exits, so tearing down needs no second password.
  Future<void> _startElevatedTun(String binary, File cfgFile) async {
    final Directory dir = await getApplicationSupportDirectory();
    final File flag = File('${dir.path}/nova-tun.run');
    await flag.writeAsString('1');
    _runFlag = flag;
    final String log = '${dir.path}/nova-tun.log';

    if (Platform.isWindows) {
      // A hidden elevated PowerShell wrapper: start the core, wait on the flag,
      // then stop it. `-Verb RunAs` raises the single UAC prompt.
      final File wrapper = File('${dir.path}/nova-tun.ps1');
      await wrapper.writeAsString(
        "${_coreEnv.entries.map((MapEntry<String, String> e) => "\$env:${e.key}='${e.value}'").join('\n')}\n"
        "\$p = Start-Process -FilePath '$binary' "
        "-ArgumentList @('run','-c','${cfgFile.path}') "
        "-WindowStyle Hidden -PassThru\n"
        "while (Test-Path '${flag.path}') { Start-Sleep -Seconds 1 }\n"
        "try { Stop-Process -Id \$p.Id -Force } catch {}\n",
      );
      _elevated = await Process.start('powershell', <String>[
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "Start-Process powershell -Verb RunAs -WindowStyle Hidden "
            "-ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"
            "'${wrapper.path}'",
      ]);
      return;
    }

    // macOS / Linux: run via an admin AppleScript (macOS) so the core gets root.
    final String envPrefix = _coreEnv.entries
        .map((MapEntry<String, String> e) => '${e.key}=${_shq(e.value)}')
        .join(' ');
    final String cmd =
        '$envPrefix ${_shq(binary)} run -c ${_shq(cfgFile.path)} > ${_shq(log)} 2>&1 & '
        'SB=\$!; while [ -e ${_shq(flag.path)} ]; do sleep 1; done; '
        'kill \$SB 2>/dev/null';
    if (Platform.isMacOS) {
      final String appleScript =
          'do shell script "${_asEsc(cmd)}" with administrator privileges';
      _elevated = await Process.start('osascript', <String>['-e', appleScript]);
    } else {
      // Linux: best-effort via pkexec (graphical sudo).
      _elevated = await Process.start('pkexec', <String>['sh', '-c', cmd]);
    }
  }

  /// Shell double-quoting for a path (handles spaces; app-support paths carry no
  /// quotes/backslashes on these platforms).
  String _shq(String p) => '"${p.replaceAll('"', r'\"')}"';

  /// Escape a shell command for embedding inside an AppleScript string literal.
  String _asEsc(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

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
        // Register the mixed inbound as an HTTP proxy for all protocols, NOT
        // `socks=`. WinINET (what Chrome/Edge use) treats `socks=` as SOCKS4,
        // which cannot tunnel HTTPS or resolve names remotely, so pages fail to
        // load. A bare host:port is an HTTP proxy and the mixed inbound speaks
        // HTTP CONNECT, so HTTPS works.
        await Process.run('reg', <String>['add', key, '/v', 'ProxyServer', '/d', '127.0.0.1:$socksPort', '/f']);
        // Keep localhost/intranet direct so loopback and LAN still resolve.
        await Process.run('reg', <String>['add', key, '/v', 'ProxyOverride', '/d', '<local>', '/f']);
      } else {
        await Process.run('reg', <String>['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
      }
      // Registry writes alone don't take effect: WinINET caches proxy settings,
      // so running browsers keep going direct until told to reload. Notify it.
      await _refreshWinInet();
      _systemProxyOn = on;
    }
  }

  /// Tell WinINET its proxy settings changed so already-running browsers pick
  /// them up immediately (otherwise the registry write is ignored until the
  /// browser restarts). Dart can't call the Win32 API directly, so drive it
  /// through a tiny inline P/Invoke in PowerShell. Best-effort.
  Future<void> _refreshWinInet() async {
    if (!Platform.isWindows) return;
    // The here-string terminator `"@` must be the first characters on its own
    // line, so keep it alone (no trailing `;`) and start the next statement on
    // the following line.
    const String ps =
        r'$s=@"' '\n'
        r'using System;using System.Runtime.InteropServices;' '\n'
        r'public class Wininet{[DllImport("wininet.dll",SetLastError=true)]'
        r'public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);}' '\n'
        r'"@' '\n'
        r'Add-Type $s;'
        r'[Wininet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)|Out-Null;'
        r'[Wininet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)|Out-Null;';
    try {
      await Process.run('powershell', <String>['-NoProfile', '-Command', ps])
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Non-fatal: the proxy is set, it just may need a browser restart to apply.
    }
  }

  Future<List<String>> _macServices() async {
    try {
      final r = await Process.run('networksetup', <String>['-listallnetworkservices']);
      final List<String> lines = (r.stdout as String).split('\n');
      // Every enabled service (a leading '*' marks a disabled one). Narrowing to
      // literal "Wi-Fi"/"Ethernet" used to silently skip machines on USB-C
      // ethernet, Thunderbolt bridge, or localized service names, leaving the
      // system proxy unset. Skip the header line networksetup prints first.
      return lines
          .where((String l) =>
              l.isNotEmpty && !l.startsWith('*') && !l.contains('asterisk'))
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      return <String>['Wi-Fi'];
    }
  }

  Future<void> _onProcessExit(int code) async {
    // A core that dies DURING startup is surfaced by connect()/_waitForCore
    // with the FATAL reason, so only handle a core that dies after we were
    // already connected here (avoids a second, less specific failure).
    if (_state == ProxyConnectionState.connected) {
      await _cleanup();
      final String tail = _coreTailText();
      _fail('The core stopped${tail.isEmpty ? '' : ': $tail'} (exit $code)');
    }
  }

  Future<void> _cleanup() async {
    _trafficTimer?.cancel();
    _trafficTimer = null;
    if (_systemProxyOn) {
      await _setSystemProxy(false);
    }
    // Dropping the run flag lets the elevated watcher kill the core and exit, so
    // no second admin prompt is needed to disconnect.
    if (_runFlag != null) {
      try {
        if (_runFlag!.existsSync()) _runFlag!.deleteSync();
      } catch (_) {}
      _runFlag = null;
      // Give the watcher a moment to tear the core down before we return.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    _elevated?.kill();
    _elevated = null;
    _process?.kill();
    _process = null;
    _stopXray();
    // Flush and close the tee log so the last core output (a FATAL reason) is
    // on disk for the user to send.
    try {
      await _coreLogSink?.flush();
      await _coreLogSink?.close();
    } catch (_) {}
    _coreLogSink = null;
    _traffic = TrafficStats.zero;
  }

  /// Kill any leftover Nova sing-box core that survived a previous session and
  /// is still holding the local ports, so a fresh connect can bind. Matches ONLY
  /// our own core by its config-file argument ([cfgPath] ends in
  /// `nova-singbox.json`), never a sing-box the user runs for their own reasons.
  /// Best-effort and fast: any failure here just falls through to the normal
  /// "address already in use" report if the port really is stuck.
  Future<void> _killStaleCores(String cfgPath) async {
    // The config filename is our unique marker; the full path differs by user.
    final String marker = cfgPath.split(Platform.pathSeparator).last;
    try {
      if (Platform.isWindows) {
        // WMIC/PowerShell: stop sing-box.exe instances whose command line ran
        // our config, leaving any unrelated sing-box alone.
        await Process.run('powershell', <String>[
          '-NoProfile',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='sing-box.exe'\" | "
              "Where-Object { \$_.CommandLine -like '*$marker*' } | "
              'ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }',
        ]).timeout(const Duration(seconds: 6));
      } else {
        // macOS/Linux: pkill matching the full command line (the config path).
        await Process.run('pkill', <String>['-f', marker])
            .timeout(const Duration(seconds: 6));
      }
      // Give the OS a beat to release the socket before we bind it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (_) {
      // No stale core, tool missing, or timed out: proceed and let the real
      // bind attempt surface any genuine conflict.
    }
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
