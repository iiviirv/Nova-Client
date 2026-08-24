import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../features/cloudflare/doh_resolver.dart';
import '../cleanip/clean_ip_finder.dart';
import '../cleanip/clean_ip_fronting.dart';
import '../cleanip/clean_ip_store.dart';
import '../logging/nova_log.dart';
import '../update/update_checker.dart';
import '../models/proxy_profile.dart';
import 'core_features.dart';
import 'measure_runner.dart';
import 'proxy_controller.dart';
import 'singbox_proxy_controller.dart'
    show isBlockedConnectionNoise, SingboxProxyController;
import 'subscription.dart';
import 'singbox/awg_config.dart';
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
    int socksPort = kDefaultLocalProxyPort,
    this.clashPort = 9191,
    this.manageSystemProxy = true,
  }) : _socksPort = socksPort;

  /// The local SOCKS/HTTP port proxy mode listens on. Settable because 2080 is
  /// a popular default and collides with other proxy apps; a user who has one
  /// of those needs to be able to move Nova rather than uninstall it. Changing
  /// it takes effect on the next connect.
  int _socksPort;
  int get socksPort => _socksPort;
  set socksPort(int port) {
    final int p = port.clamp(1, 65535);
    if (p == _socksPort) return;
    _socksPort = p;
    notifyListeners();
  }

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

  AppLifecycleListener? _lifecycle;

  /// Whether a window is on screen to read the live numbers. Hidden to the menu
  /// bar counts as not visible.
  bool _visible = true;

  /// The app's end of the elevated shell's control FIFO (macOS/Linux). Held
  /// open while the tunnel runs; closing it tells the shell to kill the core.
  RandomAccessFile? _tunCtl;

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

  /// `node-i` outbound tag -> stable node key for the current auto-select pool,
  /// so the core's per-node urltest results (which come back keyed by tag) can
  /// be attributed to the right server. Empty for a single/pinned node, which
  /// has no urltest group.
  Map<String, String> _coreTagKeys = const <String, String>{};

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

  /// Polls the core's per-node urltest history (slower than traffic: it only
  /// changes when the urltest re-measures) into [coreHealth].
  Timer? _healthTimer;
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

  /// Whether to set the OS system proxy automatically on connect in proxy
  /// mode (Settings > Routing). Defaults to yes; a user who only wants the
  /// local port for specific apps can turn it off.
  bool Function()? autoSystemProxyProvider;
  bool get autoSystemProxy =>
      autoSystemProxyProvider?.call() ?? manageSystemProxy;

  @override
  int? get localProxyPort => tunMode ? null : socksPort;

  @override
  bool get systemProxyOn => _systemProxyOn;

  @override
  Future<bool> setSystemProxy(bool on) async {
    await _setSystemProxy(on, force: true);
    notifyListeners();
    return _systemProxyOn == on;
  }

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
    // Same rule as the mobile controller: never run a measuring core and the
    // tunnel at once. The connect the user just asked for wins.
    if (measuring.value) {
      NovaLog.instance.write('Connecting, so the running server test is stopped');
      await cancelMeasure();
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
        // The system proxy needs an admin prompt on macOS. Setting it here,
        // inline, held the whole connect: the core was already serving on the
        // local port while the UI sat on "Connecting..." behind a password
        // dialog the user might never answer (reproduced on macOS). The tunnel
        // is up as soon as the core answers; point the OS at it in the
        // background and let the dashboard's Proxy mode card report the
        // result.
        unawaited(_setSystemProxy(true).then((_) => notifyListeners()));
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
      // AmneziaWG/WireGuard: the core parses the peer Endpoint with ParseAddr
      // and rejects a hostname, so a `.conf` with `Endpoint = vpn.example.com`
      // FATALs at startup. Mobile has resolved such endpoints to an IP since
      // the AWG core shipped; desktop never did, which is why the same config
      // connected on Android and failed on Windows (reported as a UAC problem,
      // see _startElevatedTun) and macOS. Same rewrite here.
      nodes = await _frontWithCleanIp(await _resolveEndpointHosts(nodes));
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
      // Remember which real node each `node-i` tag maps to, so the core's live
      // per-node latency (read back from the Clash API) lands on the right
      // server in the list. Only a real multi-node pool has a urltest group.
      if (nodes.length == 1) {
        _coreTagKeys = const <String, String>{};
      } else {
        final List<String> keys =
            SingboxConfig.orderedMultiNodeKeys(nodes, options: opts);
        _coreTagKeys = <String, String>{
          for (int i = 0; i < keys.length; i++) 'node-$i': keys[i],
        };
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
    // Re-copy whenever the app's build changes, not when the file size does.
    //
    // Size is not a version. The core is rebuilt from a pinned source, and a
    // small source change routinely produces a byte-identical LENGTH: the fix
    // for the AmneziaWG crash-on-disconnect did exactly that, going from
    // 47727954 bytes to 47727954 bytes. Anyone who had run Nova before that
    // release kept the crashing core in their application-support folder
    // through every later update, because the copy "matched", and the only way
    // out was to know to delete that folder by hand. A tester spent days on it.
    //
    // The build number is written beside the copy and compared instead, so each
    // new release refreshes the core exactly once and a same-size rebuild can
    // never be mistaken for the same binary.
    final File stamp = File('${dir.path}/core.build');
    final String want = kNovaBuild;
    final String have = stamp.existsSync()
        ? (await stamp.readAsString()).trim()
        : '';
    if (!out.existsSync() ||
        have != want ||
        out.lengthSync() != src.lengthSync()) {
      await src.copy(out.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['+x', out.path]);
      }
      try {
        await stamp.writeAsString(want);
      } catch (_) {
        // A missing stamp only costs one extra copy next launch.
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
    } else if (Platform.isLinux) {
      // Same purego NaiveProxy path as Windows, with the ELF shared object.
      // Linux needs no wintun equivalent: the kernel provides /dev/net/tun and
      // sing-box opens it directly once the core is elevated.
      await _ensureSideDll(dir, 'libcronet.so');
    }
    // Remembered so a TUN failure can say which binary it actually launched.
    _lastCorePath = out.path;
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

  /// Mirror a shared library that ships beside the core into the run directory,
  /// so the core finds it in its own directory at load time. No-op when it was
  /// not shipped (an older bundle), which just leaves the matching feature off.
  Future<void> _ensureSideDll(Directory dir, String name) async {
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    final String sep = Platform.isWindows ? '\\' : '/';
    final File src = <File>[
      File('${exeDir.path}$sep$name'),
      // On Linux the bundle puts the core under lib/ alongside the runner's
      // data, so look there too before falling back to a source-tree run.
      File('${exeDir.path}${sep}lib$sep$name'),
      File('assets/bin/$name'),
    ].firstWhere((File f) => f.existsSync(),
        orElse: () => File('${exeDir.path}$sep$name'));
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
  /// macOS `Nova.app/Contents/Resources/`, Windows next to `nova_client.exe`,
  /// Linux next to the runner or under its `lib/` (where a Flutter Linux bundle
  /// keeps its shared files). Falls back to the repo `assets/bin/` path when
  /// running from source (`flutter run`), where the executable lives in the
  /// build tree.
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
    } else if (Platform.isLinux) {
      for (final String p in <String>[
        '${exeDir.path}/$name',
        '${exeDir.path}/lib/$name',
      ]) {
        final File f = File(p);
        if (f.existsSync()) return f;
      }
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

  /// Rewrites any AmneziaWG/WireGuard node whose peer Endpoint is a domain to
  /// use a resolved IPv4, the way the mobile controller does. Non-endpoint
  /// nodes and already-numeric endpoints pass through untouched; an
  /// unresolvable host passes through too (the core then reports it).
  @visibleForTesting
  Future<List<ProxyNode>> resolveEndpointHostsForTest(List<ProxyNode> nodes) =>
      _resolveEndpointHosts(nodes);

  /// Test seam: replaces the system/DoH lookup used for endpoint hosts.
  @visibleForTesting
  Future<String?> Function(String host)? hostResolverOverride;


  /// Dial Cloudflare-fronted servers through a clean address this device found,
  /// keeping their domain as the TLS name.
  ///
  /// Only for a profile with the SNI-block bypass on, which is the case this
  /// exists for: a public subscription's domains get filtered within days while
  /// the addresses behind them keep working, and the bypass itself only applies
  /// to a node that is already addressed by IP. Nodes that do not actually
  /// resolve onto Cloudflare are left exactly as their provider wrote them.
  ///
  /// Never blocks on a search. The first connect may go out unfronted; the scan
  /// it starts is what makes the next one work.
  Future<List<ProxyNode>> _frontWithCleanIp(List<ProxyNode> nodes) async {
    if (!(_active?.hardenTls ?? false)) return nodes;
    if (!nodes.any(CleanIpFronting.couldBeFronted)) return nodes;
    final CleanIp? ip = CleanIpFinder.current();
    if (ip == null) {
      CleanIpFinder.ensure();
      return nodes;
    }
    return CleanIpFronting.apply(nodes, ip);
  }

  Future<List<ProxyNode>> _resolveEndpointHosts(List<ProxyNode> nodes) async {
    final List<ProxyNode> out = <ProxyNode>[];
    for (final ProxyNode n in nodes) {
      final String? conf = n.awgConf;
      if (!n.protocol.isEndpoint || conf == null || conf.isEmpty) {
        out.add(n);
        continue;
      }
      final String? host = awgEndpointHost(conf);
      if (host == null || InternetAddress.tryParse(host) != null) {
        out.add(n);
        continue;
      }
      final String? ip = await (hostResolverOverride ?? _resolveHostToIp)(host);
      if (ip == null) {
        NovaLog.instance.write(
          'AWG endpoint $host did not resolve; the core may reject the name',
          level: NovaLogLevel.warn,
        );
        out.add(n);
      } else {
        NovaLog.instance.write(
            'AWG endpoint $host -> $ip (the core needs a numeric endpoint)');
        out.add(n.copyWith(awgConf: rewriteAwgEndpointHost(conf, ip)));
      }
    }
    return out;
  }

  /// System resolver first, DoH second (Iran's ISPs answer some names with
  /// poison or nothing; DoH goes around that before the tunnel exists).
  Future<String?> _resolveHostToIp(String host) async {
    try {
      final List<InternetAddress> a = await InternetAddress.lookup(host,
              type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 4));
      if (a.isNotEmpty) return a.first.address;
    } catch (_) {}
    try {
      final List<String> a =
          await DohResolver().resolveA(host).timeout(const Duration(seconds: 6));
      if (a.isNotEmpty) return a.first;
    } catch (_) {}
    return null;
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
          // Prefer the core's own FATAL/ERROR line over the tail of the log.
          //
          // The tail is the wrong place to look. When the core dies it prints
          // the reason and then a Go stack, so the last three lines are
          // "cobra/command.go", "main.main()" and an address, and the user is
          // shown a stack trace with the cause scrolled off the top. A tester
          // on an Intel Mac reported exactly that: a message naming
          // spf13/cobra, which says nothing about what went wrong.
          final RegExp level = RegExp(r'\b(FATAL|ERROR)\b');
          final List<String> named =
              lines.where((String l) => level.hasMatch(l)).toList();
          if (named.isNotEmpty) {
            // The last one, and the line after it when that carries the
            // remedy: sing-box splits "X is deprecated" from "to continue
            // using this feature, set ..." across two lines.
            final int at = lines.lastIndexOf(named.last);
            reason = lines
                .sublist(at, (at + 2).clamp(0, lines.length))
                .join(' | ');
          } else {
            reason =
                lines.sublist(lines.length > 3 ? lines.length - 3 : 0).join(' | ');
          }
        }
      }
    } catch (_) {
      // Best-effort; fall back to the generic guidance below.
    }
    if (reason.isEmpty) {
      // No tun log means the elevated core never wrote one. WHY it did not is
      // three different problems, and this used to answer all three with
      // "approve the admin prompt". That guess cost two rounds of debugging with
      // a tester who was already running the app under sudo: there was no prompt
      // to approve, so the advice was not just unhelpful but impossible to act
      // on. Say what actually happened instead, and when we genuinely do not
      // know, say that and hand over the evidence.
      final String elev = _elevationError;
      if (elev.isNotEmpty && !elev.contains('User canceled')) {
        return 'Full-device mode could not get administrator access: $elev. '
            'You can turn off full-device mode in Settings to use proxy mode, '
            'which needs no admin access.';
      }
      if (elev.contains('User canceled')) {
        return 'Full-device mode needs the administrator prompt approved so it '
            'can create the network adapter. Approve it and try again, or turn '
            'off full-device mode in Settings to use proxy mode, which needs no '
            'admin access.';
      }
      // The helper did not report a failure, so elevation is not the story: the
      // core was launched and produced nothing. Report what we can actually see
      // about it, which is what a support conversation needs.
      final StringBuffer facts = StringBuffer();
      try {
        final File bin = File(_lastCorePath);
        facts.write(' Core: ');
        facts.write(_lastCorePath.isEmpty ? '(never copied)' : _lastCorePath);
        if (_lastCorePath.isNotEmpty) {
          facts.write(bin.existsSync()
              ? ' (present, ${bin.lengthSync()} bytes)'
              : ' (MISSING)');
        }
      } catch (_) {
        // Diagnostics must never be the thing that throws.
      }
      return 'Full-device mode started the core with administrator access, but '
          'it exited without writing a log, so it failed before it could say '
          'why.$facts Expected log: $logPath. Please send that path and the '
          'app log to support. Proxy mode works without any of this: turn off '
          'full-device mode in Settings.';
    }
    // The core ran but failed: surface its actual reason and the log path.
    return 'Full-device mode failed to start: $reason. Log: $logPath. You can '
        'turn off full-device mode in Settings to use proxy mode instead.';
  }

  /// What the elevation helper last said, if it failed.
  ///
  /// Nothing read osascript's output, so every failure to elevate looked
  /// identical to the app: no tun log, therefore "the prompt was probably
  /// dismissed". That guess is right often enough to be misleading, and a
  /// tester chasing a full-device failure was told to approve a prompt he had
  /// already approved. osascript is specific when asked: cancelling gives
  /// "User canceled. (-128)", and anything else is a different problem
  /// entirely.
  String _elevationError = '';

  /// The core binary the last run copied into place, for failure reporting.
  String _lastCorePath = '';

  void _watchElevation(Process p, String helper) {
    _elevationError = '';
    final StringBuffer err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write, onError: (Object _) {});
    unawaited(p.exitCode.then((int code) {
      if (code == 0) return;
      final String text = err.toString().trim();
      _elevationError = text.isEmpty ? '$helper exited $code' : text;
      NovaLog.instance.write('Elevation failed ($helper, exit $code): '
          '${text.isEmpty ? "no output" : text}');
    }));
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

  /// Live traffic and per-node health, polled off the core's Clash API.
  ///
  /// Both of these only feed things on screen: the download/upload readout and
  /// the server list's live pings. With the window closed there is nobody to
  /// read them, so they stop, and a once-a-second HTTP request stops keeping the
  /// machine out of its idle states for a number nobody is looking at. That
  /// matters more since closing the window began leaving Nova running in the
  /// menu bar rather than quitting: for most of a session there is no window.
  void _startTrafficPolling() {
    _lastUp = 0;
    _lastDown = 0;
    _lifecycle ??= AppLifecycleListener(onStateChange: _onLifecycle);
    _armPolling();
  }

  void _armPolling() {
    _trafficTimer?.cancel();
    _healthTimer?.cancel();
    if (!_visible) return;
    _trafficTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollTraffic());
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollHealth());
    // Prime it straight away so the list gets numbers as soon as the pool has
    // been measured once, instead of waiting a full interval.
    _pollHealth();
  }

  void _onLifecycle(AppLifecycleState state) {
    final bool visible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (visible == _visible) return;
    _visible = visible;
    if (_state.isActive) _armPolling();
  }

  /// Read the core's per-node urltest results off the Clash API and publish
  /// them as [coreHealth], the same shape the Android host streams. This is what
  /// puts a real, through-the-tunnel ping on nodes the outside probe has to
  /// call "not testable" (Reality, obfuscated Hysteria2, SS2022, xhttp): the
  /// core measured them itself. Desktop never fed this before, so those nodes
  /// stayed "not testable" even while connected through them.
  ///
  /// `GET /proxies` returns every outbound with a `history` of `{time, delay}`
  /// and, for the urltest group, `now` (the selected member). We reshape that
  /// into the `groups` payload [SingboxProxyController.parseCoreGroups] already
  /// understands, so both platforms share one parser.
  Future<void> _pollHealth() async {
    if (_coreTagKeys.isEmpty) return;
    try {
      final r = await http
          .get(Uri.parse('http://127.0.0.1:$clashPort/proxies'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode != 200) return;
      final CoreNodeHealth next = healthFromClashProxies(
          _coreTagKeys, (jsonDecode(r.body) as Map).cast<String, dynamic>());
      final CoreNodeHealth cur = coreHealth.value;
      // Fold in rather than replace: see CoreNodeHealth.withLive.
      final CoreNodeHealth merged = measuring.value ? next : cur.withLive(next);
      if (merged.selectedKey == cur.selectedKey &&
          mapEquals(merged.delayMsByKey, cur.delayMsByKey) &&
          setEquals(merged.testedKeys, cur.testedKeys)) {
        return;
      }
      coreHealth.value = merged;
    } catch (_) {}
  }

  // ---- "test all through the core": a second, tunnel-less measuring core ----

  @override
  bool get canMeasureNodes => true;

  Process? _measureProcess;

  @override
  Future<String?> measureNodes(List<ProxyNode> nodes,
      {bool merge = false, int? stopAfterWorking}) async {
    if (measuring.value) return null;
    if (nodes.isEmpty) return null;
    if (tunMode && (_state.isActive || _state.isBusy)) {
      // In full-device mode every dial the measuring core makes would itself
      // go through the live tunnel, so the numbers would be the current exit
      // plus the node, not the node. The live pool already has honest figures
      // while connected; measuring everything needs the tunnel down.
      return 'Disconnect first to measure all servers in full-device mode.';
    }
    measuring.value = true;
    Process? proc;
    final List<String> tail = <String>[];
    try {
      final int mixedPort = await _freeLoopbackPort();
      final int apiPort = await _freeLoopbackPort();
      final SingboxRouteOptions opts = routeOptions.copyWith(
        localRuleSets: true,
        hardenTls: _active?.hardenTls ?? false,
        hardenPacketFragment: !Platform.isWindows,
      );
      final List<ProxyNode> resolved =
          await _frontWithCleanIp(await _resolveEndpointHosts(nodes));
      final String binary = await _ensureBinary();
      final Directory dir = await getApplicationSupportDirectory();
      // xhttp nodes run on the Xray core (one local socks inbound each); the
      // measuring core lists them as socks exits, so they get a number too.
      // Only when this build carries an Xray binary; otherwise they stay out
      // of the pool, as before.
      bool xhttp = false;
      final List<ProxyNode> xhttpNodes = SingboxConfig.pickedXhttpNodes(
          resolved, options: opts, poolCap: SingboxConfig.kMeasurePoolCap);
      if (xhttpNodes.isNotEmpty && await _ensureXrayBinary() != null) {
        final List<ProxyNode> resolvedX = <ProxyNode>[
          for (final ProxyNode x in xhttpNodes) await _resolveXhttpServer(x),
        ];
        xhttp = await _startXray(dir,
            XrayConfig.buildMulti(resolvedX, basePort: _xraySocksPort));
      }
      final ({Map<String, dynamic> config, Map<String, String> tagKeys}) built =
          SingboxConfig.buildMeasureMap(resolved,
              options: opts,
              mixedPort: mixedPort,
              clashPort: apiPort,
              includeXhttp: xhttp,
              xhttpBasePort: _xraySocksPort);
      final File cfgFile = File('${dir.path}/nova-measure.json');
      await cfgFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(built.config));
      final CoreNodeHealth before = coreHealth.value;
      if (!merge) coreHealth.value = CoreNodeHealth.empty;
      NovaLog.instance.write(
          'Measuring ${built.tagKeys.length} servers through the core');

      proc = await Process.start(binary, <String>['run', '-c', cfgFile.path],
          environment: _coreEnv);
      _measureProcess = proc;
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String l) {
        tail.add(l);
        if (tail.length > 12) tail.removeAt(0);
      });
      unawaited(proc.stdout.drain<void>());
      bool exited = false;
      unawaited(proc.exitCode.then((_) => exited = true));

      final Uri api = Uri.parse('http://127.0.0.1:$apiPort/');
      if (!await MeasureRunner.waitForApi(api,
          cancelled: () => exited || !measuring.value)) {
        final String why = tail.isEmpty ? 'it did not start' : tail.join(' | ');
        return 'Could not start the measuring core: $why';
      }

      final int timeoutSec = opts.urlTestTimeoutSec.clamp(1, 60);
      final List<String> failures = <String>[];
      final Map<String, int> delays = await MeasureRunner.run(
        api: api,
        failures: failures,
        tagKeys: built.tagKeys,
        url: opts.urlTestUrl,
        timeoutSec: timeoutSec,
        stopAfterWorking: stopAfterWorking,
        cancelled: () => exited || !measuring.value,
        onProgress: (Map<String, int> d, Set<String> tested) {
          coreHealth.value = _mergeHealth(before, d, tested, merge: merge);
        },
      );
      // Final verdicts: everything in the pool was tried; a node with no
      // delay is "no response", not "not testable".
      coreHealth.value = _mergeHealth(
          before, delays, built.tagKeys.values.toSet(), merge: merge);
      NovaLog.instance.write(
          'Measured ${built.tagKeys.length} servers through the core: '
          '${delays.length} answered'
          '${delays.isEmpty && failures.isNotEmpty ? '. Why: ${failures.join('; ')}' : ''}');
      return null;
    } on FormatException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not measure: $e';
    } finally {
      proc?.kill();
      _measureProcess = null;
      _stopXray();
      measuring.value = false;
    }
  }

  @override
  Future<void> cancelMeasure() async {
    if (!measuring.value) return;
    // Same contract as the mobile controller: clearing the flag stops the run
    // (every `cancelled:` callback watches it) and the core is killed here so a
    // dial still waiting out its timeout does not keep the process alive after
    // the user has asked it to stop.
    measuring.value = false;
    _measureProcess?.kill();
    _measureProcess = null;
    _stopXray();
    NovaLog.instance.write('Measuring stopped');
  }

  /// Folds one run's results into whatever the board already shows. A run that
  /// covers the whole list ([merge] false) replaces it; re-testing a single row
  /// keeps every other row's verdict.
  CoreNodeHealth _mergeHealth(
    CoreNodeHealth before,
    Map<String, int> delays,
    Set<String> tested, {
    required bool merge,
  }) {
    if (!merge) {
      return CoreNodeHealth(delayMsByKey: delays, testedKeys: tested);
    }
    final Map<String, int> d = Map<String, int>.from(before.delayMsByKey);
    for (final String k in tested) {
      d.remove(k);
    }
    d.addAll(delays);
    return CoreNodeHealth(
      delayMsByKey: d,
      testedKeys: <String>{...before.testedKeys, ...tested},
      selectedKey: before.selectedKey,
    );
  }

  /// A free TCP port on loopback for the measuring core's inbound and API, so
  /// it never collides with the tunnel core's fixed ports or another app.
  Future<int> _freeLoopbackPort() async {
    final ServerSocket s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = s.port;
    await s.close();
    return port;
  }

  /// Reshape the Clash API's `GET /proxies` body into [CoreNodeHealth] for the
  /// given `node-i` tag map. Pure, so it is unit-tested against the exact JSON
  /// the shipped core returns.
  @visibleForTesting
  static CoreNodeHealth healthFromClashProxies(
      Map<String, String> tagKeys, Map<String, dynamic> body) {
      final Map<String, dynamic> all =
          (body['proxies'] as Map).cast<String, dynamic>();
      final Map<String, dynamic>? group =
          (all['proxy'] as Map?)?.cast<String, dynamic>();
      final List<Map<String, Object?>> items = <Map<String, Object?>>[];
      for (final String tag in tagKeys.keys) {
        final Map<String, dynamic>? p = (all[tag] as Map?)?.cast<String, dynamic>();
        if (p == null) continue;
        final List<dynamic> hist = (p['history'] as List<dynamic>?) ?? <dynamic>[];
        // Newest sample last; a missing/failed measurement is 0, which the
        // parser treats as "tested, no answer".
        final int delay = hist.isEmpty
            ? 0
            : ((hist.last as Map)['delay'] as num?)?.toInt() ?? 0;
        items.add(<String, Object?>{'tag': tag, 'delay': delay});
      }
      final Object groups = <Map<String, Object?>>[
        <String, Object?>{
          'tag': 'proxy',
          'selected': group?['now'],
          'items': items,
        },
      ];
      return SingboxProxyController.parseCoreGroups(tagKeys, groups);
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
  /// Every platform uses the same single-prompt trick: the elevated shell starts
  /// the core and then waits for the app to say "stop", so tearing down needs no
  /// second password.
  ///
  /// On macOS and Linux the launch is DETACHED, and that is the important part.
  ///
  /// A user on a 2015 MacBook Pro reported `osascript` sitting at 10-12% CPU
  /// for as long as the tunnel was up, the CPU pinned at 3GHz instead of
  /// dropping to 1.5GHz, and the machine running 20C hotter, all of it gone the
  /// instant they disconnected. The obvious suspect was the old
  /// `while [ -e flag ]; do sleep 1; done` watcher, since `sleep` is not a
  /// builtin and that forks a process every second forever. Measuring said
  /// otherwise: over 20 seconds the sleep loop and a blocked `cat` cost
  /// osascript exactly the same, 0.97s against 0.99s of CPU. The loop was not
  /// the cost. **osascript itself burns about 5% of a core just staying alive**
  /// while `do shell script` waits on its command, whatever that command does.
  ///
  /// So the command is backgrounded with every descriptor closed, which leaves
  /// `do shell script` nothing to wait on: osascript spawns the work and exits,
  /// and no osascript process remains. Measured the same way, what is left uses
  /// 0.01s of CPU over 20 seconds, which is to say none.
  ///
  /// The waiter then blocks reading a FIFO instead of polling a flag file. That
  /// is worth doing on its own (no fork per second) but it also makes the
  /// teardown safe: the kernel closes the app's end of the FIFO when the app
  /// dies, so a crash kills the root core too. The old flag file could not do
  /// that, because a crashed app never deleted it.
  ///
  /// Windows keeps the flag-file loop. PowerShell's `Start-Sleep` is a real
  /// sleep with no process spawn, there is no osascript equivalent holding the
  /// session open, and named pipes there are a bigger change than the evidence
  /// justifies.
  Future<void> _startElevatedTun(String binary, File cfgFile) async {
    final Directory dir = await getApplicationSupportDirectory();
    final File flag = File('${dir.path}/nova-tun.run');
    await flag.writeAsString('1');
    _runFlag = flag;
    final String log = '${dir.path}/nova-tun.log';

    if (Platform.isWindows) {
      // A hidden elevated PowerShell wrapper: start the core, wait on the flag,
      // then stop it. `-Verb RunAs` raises the single UAC prompt.
      //
      // Two things this used to get wrong, both of which ended in the user
      // being told "approve the UAC prompt" after they had approved it:
      //
      // 1. The core's output was never captured. sing-box logs to stderr, and
      //    without -RedirectStandardError nothing was written, so
      //    [_tunFailureMessage] found no log and fell back to the UAC text no
      //    matter why the core actually died. It now writes stderr to
      //    nova-tun.log (what the diagnosis reads) and stdout to
      //    nova-tun.out.log (PowerShell refuses the same file for both).
      // 2. Windows PowerShell 5.1 joins -ArgumentList with spaces and does not
      //    quote elements that contain one, so a config path under a profile
      //    like `C:\Users\Ali Reza\...` was split into several arguments and
      //    the core never started. Paths are now quoted inside the element.
      //
      // A stale log from a previous run is removed first so a failure is never
      // diagnosed from an older session's last lines.
      final File errLog = File(log);
      final File outLog = File('${dir.path}/nova-tun.out.log');
      for (final File f in <File>[errLog, outLog]) {
        try {
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      }
      final File wrapper = File('${dir.path}/nova-tun.ps1');
      await wrapper.writeAsString(
        "${_coreEnv.entries.map((MapEntry<String, String> e) => "\$env:${e.key}='${e.value}'").join('\n')}\n"
        "\$p = Start-Process -FilePath '$binary' "
        "-ArgumentList @('run','-c','\"${cfgFile.path}\"') "
        "-RedirectStandardError '$log' "
        "-RedirectStandardOutput '${outLog.path}' "
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
            "'\"${wrapper.path}\"'",
      ]);
      return;
    }

    // macOS / Linux: run via an admin AppleScript (macOS) so the core gets root.
    final File ctl = File('${dir.path}/nova-tun.ctl');
    await _makeFifo(ctl);
    final String envPrefix = _coreEnv.entries
        .map((MapEntry<String, String> e) => '${e.key}=${_shq(e.value)}')
        .join(' ');
    // The work itself: start the core, then block reading the control FIFO
    // until the app closes its end, then stop the core.
    final String inner =
        '$envPrefix ${_shq(binary)} run -c ${_shq(cfgFile.path)} > ${_shq(log)} 2>&1 & '
        'SB=\$!; cat ${_shq(ctl.path)} > /dev/null 2>&1; '
        'kill \$SB 2>/dev/null';
    // Detached, with every file descriptor closed, so `do shell script` has
    // nothing left to wait on and osascript exits immediately. See the note on
    // this method: an osascript left supervising the session IS the 5%.
    final String cmd = 'nohup sh -c ${_shSingleQ(inner)} > /dev/null 2>&1 &';
    if (Platform.isMacOS) {
      final String appleScript =
          'do shell script "${_asEsc(cmd)}" with administrator privileges';
      _elevated = await Process.start('osascript', <String>['-e', appleScript]);
      _watchElevation(_elevated!, 'osascript');
    } else {
      // Linux: best-effort via pkexec (graphical sudo).
      _elevated = await Process.start('pkexec', <String>['sh', '-c', cmd]);
      _watchElevation(_elevated!, 'pkexec');
    }
    // Held open for the whole session; closing it in [_cleanup] is the stop
    // signal, and losing it to a crash is the same signal.
    try {
      _tunCtl = await File(ctl.path).open(mode: FileMode.write);
    } catch (e) {
      // Without the handle the tunnel still runs, and _cleanup falls back to
      // opening the FIFO itself to release the waiting shell.
      NovaLog.instance.write('Could not hold the tunnel control channel: $e',
          level: NovaLogLevel.warn);
    }
  }

  /// Creates the control FIFO, replacing any left by an earlier run.
  Future<void> _makeFifo(File f) async {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await Process.run('mkfifo', <String>[f.path]);
  }

  /// Shell double-quoting for a path (handles spaces; app-support paths carry no
  /// quotes/backslashes on these platforms).
  String _shq(String p) => '"${p.replaceAll('"', r'\"')}"';

  /// Single-quoting, for embedding a whole command as one `sh -c` argument.
  /// Single quotes protect everything else, so the only case to handle is a
  /// literal single quote, which has to leave and re-enter the quoting.
  String _shSingleQ(String s) {
    final String escaped = s.replaceAll("'", r"'\''");
    return "'$escaped'";
  }

  /// Escape a shell command for embedding inside an AppleScript string literal.
  String _asEsc(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// Point the OS at our local proxy (or clear it). macOS/Windows for now.
  /// [force] bypasses the auto-set preference (the dashboard's button).
  Future<void> _setSystemProxy(bool on, {bool force = false}) async {
    if (on && !force && !autoSystemProxy) return;
    if (Platform.isMacOS) {
      final List<String> services = await _macServices();
      final List<String> cmds = <String>[];
      for (final String s in services) {
        if (on) {
          // SOCKS for apps that speak it, plus HTTP/HTTPS web proxy (the
          // mixed inbound answers both), so apps that only honour the web
          // proxy settings (many Electron and CLI tools) are covered too.
          cmds.add('networksetup -setsocksfirewallproxy "$s" 127.0.0.1 $socksPort');
          cmds.add('networksetup -setsocksfirewallproxystate "$s" on');
          cmds.add('networksetup -setwebproxy "$s" 127.0.0.1 $socksPort');
          cmds.add('networksetup -setwebproxystate "$s" on');
          cmds.add('networksetup -setsecurewebproxy "$s" 127.0.0.1 $socksPort');
          cmds.add('networksetup -setsecurewebproxystate "$s" on');
        } else {
          cmds.add('networksetup -setsocksfirewallproxystate "$s" off');
          cmds.add('networksetup -setwebproxystate "$s" off');
          cmds.add('networksetup -setsecurewebproxystate "$s" off');
        }
      }
      if (cmds.isEmpty) return;
      // One authorization prompt covers the whole batch.
      final String script = cmds.join(' && ').replaceAll('"', '\\"');
      final ProcessResult r = await Process.run('osascript', <String>[
        '-e',
        'do shell script "$script" with administrator privileges',
      ]);
      // A declined admin prompt (or any failure) used to be recorded as "set",
      // so the dashboard had nothing honest to show. Only a clean exit counts.
      if (r.exitCode == 0) {
        _systemProxyOn = on;
      } else {
        NovaLog.instance.write(
            'System proxy not ${on ? 'set' : 'cleared'}: ${(r.stderr as String).trim()}',
            level: NovaLogLevel.warn);
      }
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
    _healthTimer?.cancel();
    _healthTimer = null;
    // Drop the tunnel's selection, keep the measured board. A server switch is
    // a disconnect followed by a connect, and it must not cost the user their
    // lightning test.
    coreHealth.value = coreHealth.value.withoutSelection;
    _coreTagKeys = const <String, String>{};
    if (_systemProxyOn) {
      await _setSystemProxy(false);
    }
    // Releasing the elevated shell lets it kill the core and exit, so no second
    // admin prompt is needed to disconnect.
    //
    // macOS/Linux: closing our end of the FIFO gives its `cat` EOF instantly.
    // Windows still watches the flag file, so that is dropped too.
    if (_tunCtl != null || _runFlag != null) {
      final RandomAccessFile? ctl = _tunCtl;
      _tunCtl = null;
      try {
        await ctl?.close();
      } catch (_) {}
      if (ctl == null && !Platform.isWindows) {
        // We never got a handle. Open the FIFO now purely to unblock the shell
        // that is still reading it, so the root core is not orphaned.
        try {
          final Directory dir = await getApplicationSupportDirectory();
          final File f = File('${dir.path}/nova-tun.ctl');
          if (f.existsSync()) {
            final RandomAccessFile r = await f.open(mode: FileMode.write);
            await r.close();
          }
        } catch (_) {}
      }
      try {
        if (_runFlag?.existsSync() ?? false) _runFlag!.deleteSync();
      } catch (_) {}
      _runFlag = null;
      // Give the shell a moment to tear the core down before we return.
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
    // A measuring core still running when the app closes must not outlive it.
    _measureProcess?.kill();
    _measureProcess = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _cleanup();
    super.dispose();
  }
}
