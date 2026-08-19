import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/nova_log.dart';
import '../models/proxy_profile.dart';
import 'core_features.dart';
import 'isp_optimizer.dart';
import 'proxy_controller.dart';
import 'singbox/node_probe.dart';
import '../../features/cloudflare/doh_resolver.dart';
import 'singbox/awg_config.dart';
import 'singbox/proxy_node.dart';
import 'singbox/singbox_config.dart';
import 'subscription.dart';
import 'xray/xray_config.dart';

/// Phase-3 xhttp/Xray path, ON: the Android libbox.aar is the combined
/// sing-box+Xray core (io.nekohasekai.novaxray), so a single pinned xhttp node
/// runs on Xray while sing-box bridges the TUN. See docs/xray-core-scope.md.
const bool kXrayXhttpEnabled = true;

/// True for a core log line that reports a connection the core rejected via its
/// `block` outbound — QUIC/HTTP-3 on a TCP-only exit (blocked so apps fall back
/// to TCP), plus ad/geo blocks. The core logs each at ERROR ("operation not
/// permitted"), which floods the user-facing log and reads as a fault when it is
/// really the anti-QUIC / ad-block feature working. Filtered out of the quiet log
/// (kept when Detailed core log is on). Matches both the TCP form and the
/// "listen packet connection" (UDP/QUIC) form.
bool isBlockedConnectionNoise(String message) =>
    message.contains('outbound/block[block]') &&
    message.contains('operation not permitted');

/// True for a core log line that is a routine *consequence* of the device's
/// network changing (Wi-Fi to cellular, a tunnel, a lift, a doze wake) rather
/// than a fault. Two shapes, both logged by the core at ERROR:
///
/// * `connection download|upload closed: ... software caused connection abort`
///   — the OS tore down live sockets because the network under them went away.
///   One line per open connection, so a single handover can log a dozen at once.
/// * `report handshake success: connection refused` — misleading wording: by
///   that point the dial to the server has already succeeded (see sing-box
///   `route/conn.go`), and what failed was reporting that success back to the
///   local app, which gave up mid-handshake. Nothing refused us.
///
/// Without this a normal commute fills the log with red and reads as Nova being
/// broken. Filtered from the quiet log, kept when Detailed core log is on.
///
/// The `missing default interface` line that *explains* the event is
/// deliberately NOT filtered (see [coreLogLevelFor]) so the cause survives
/// without its flood of consequences.
bool isNetworkChurnNoise(String message) =>
    (message.contains('software caused connection abort') &&
        (message.contains('connection download closed') ||
            message.contains('connection upload closed'))) ||
    (message.contains('report handshake success') &&
        message.contains('connection refused'));

/// The level a core line should be shown at.
///
/// `network: missing default interface` is the core saying the device has no
/// underlying network right now, so it pauses until one returns. That is real,
/// useful context (it is the one line that explains a batch of dropped
/// connections) but it is an event, not a fault, and the core emits it at ERROR.
/// Show it as a warning so it stays visible in the quiet log without reading as
/// something broken.
NovaLogLevel coreLogLevelFor(String message, NovaLogLevel level) =>
    message.contains('missing default interface') ? NovaLogLevel.warn : level;

/// The real [ProxyController] backed by a modified **sing-box** core.
///
/// This is the **integration boundary** for the native data path. The Dart side
/// talks to the platform host over a [MethodChannel] (commands) and an
/// [EventChannel] (state + traffic stream); each platform implements the host:
///
///   * **Android** — a foreground `VpnService` that runs the sing-box core and
///     owns the TUN fd.
///   * **iOS / macOS** — a `NEPacketTunnelProvider` Network Extension.
///   * **Windows / Linux** — a privileged TUN helper service.
///
/// ### Channel contract
///
/// MethodChannel `nova.proxy/control`:
///   * `start(configJson: String)` → builds the sing-box config from the
///     active profile and starts the tunnel. Returns when the core is up.
///   * `stop()` → stops the tunnel.
///   * `status()` → returns the current [ProxyConnectionState] name.
///
/// EventChannel `nova.proxy/events` emits maps:
///   * `{ "type": "state", "value": "connected" }`
///   * `{ "type": "traffic", "up": bps, "down": bps, "upTotal": bytes, "downTotal": bytes }`
///   * `{ "type": "error", "message": "text" }`
///
/// Until the native hosts ship, the app wires up [MockProxyController]; flip the
/// instance in `main.dart` to switch over with zero UI changes.
class SingboxProxyController extends ProxyController {
  SingboxProxyController({
    MethodChannel? control,
    EventChannel? events,
    CoreFeatures? features,
  })  : _control = control ?? const MethodChannel('nova.proxy/control'),
        _events = events ?? const EventChannel('nova.proxy/events'),
        _features = features ?? CoreFeatures.instance {
    _subscribe();
  }

  final MethodChannel _control;
  final EventChannel _events;
  final CoreFeatures _features;
  StreamSubscription<dynamic>? _eventSub;

  /// If the tunnel never reports "connected" within this window the start has
  /// effectively hung (e.g. the core stuck initialising), so surface a real
  /// error instead of an endless "Connecting…".
  static const Duration _connectTimeout = Duration(seconds: 30);
  Timer? _watchdog;

  /// Bumped by every connect() and disconnect(). A connect() that finds a newer
  /// request arrived while it was resolving its subscription / building its
  /// config stops before it sends `start`, so a fast server switch (or an
  /// SNI-bypass toggle, which reconnects) can never start a stale tunnel on top
  /// of the one the user actually asked for.
  int _opSeq = 0;

  /// Clears a `disconnecting` that the platform never answered (see
  /// [disconnect]).
  Timer? _stopWatchdog;

  /// One automatic retry per session for a rule-set read error at startup.
  bool _ruleSetRetried = false;

  /// Guards the auto-mode self-heal (a single rebuild of a subscription tunnel
  /// that came up but carries no traffic) so a genuinely dead subscription can't
  /// loop reconnecting forever. Reset on each user-initiated connect/disconnect.
  bool _autoHealTried = false;

  /// True only while the self-heal is itself driving a [reconnect], so that
  /// reconnect's internal disconnect/connect don't reset [_autoHealTried] and
  /// re-arm the heal (which would let a dead subscription loop).
  bool _healing = false;

  /// Maps the config's `node-i` outbound tag to the real [proxyNodeKey], set
  /// each time a multi-node config is built. Lets a `groups` event from the core
  /// (which is keyed by those tags) be shown against the right server row.
  Map<String, String> _coreTagKeys = const <String, String>{};

  /// Maps a node's [proxyNodeKey] to the name the panel gave it, set each time a
  /// config is built. Lets the UI name the connected exit instead of showing a
  /// clean-IP node's meaningless Cloudflare address.
  Map<String, String> _keyToName = const <String, String>{};

  /// Set by [_buildSingboxConfig] when the exit is an xhttp node: the Xray core
  /// config the native host starts alongside the sing-box TUN->SOCKS bridge.
  String? _pendingXrayConfig;

  @override
  String? exitName(String? key) => key == null ? null : _keyToName[key];

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

  void _subscribe() {
    _eventSub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) {
        _lastError = e.toString();
        _state = ProxyConnectionState.error;
        notifyListeners();
      },
    );
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'log':
        // One line, or a batch, straight from the core. The host sends
        // `{ "type": "log", "lines": [ { "level": int, "message": String } ] }`.
        //
        // The level is filtered HERE rather than trusted from the config.
        // libbox's log stream carries everything the core produces regardless of
        // `log.level` (measured on a device: TRACE and DEBUG arrived with the
        // config set to `warn`), so leaving it to the config meant the Detailed
        // switch did nothing and every user got a firehose. Gating on the
        // setting makes the switch true whatever the core decides to emit.
        final bool verbose = routeOptions.verboseCoreLog;
        final Object? lines = event['lines'];
        if (lines is List) {
          for (final Object? line in lines) {
            if (line is! Map) continue;
            final String message = '${line['message']}';
            final NovaLogLevel level =
                novaLogLevelFromCore((line['level'] as num?)?.toInt() ?? 4);
            // Connections the core sends to the `block` outbound are rejected BY
            // DESIGN (see isBlockedConnectionNoise); hide that flood unless the
            // user turned on Detailed core log.
            if (!verbose && isBlockedConnectionNoise(message)) continue;
            // Sockets torn down because the device changed network are expected
            // (see isNetworkChurnNoise); hide the per-connection flood but keep
            // the one line that explains it.
            if (!verbose && isNetworkChurnNoise(message)) continue;
            final NovaLogLevel shown = coreLogLevelFor(message, level);
            // Quiet means what `log.level: warn` was supposed to mean: the core's
            // complaints, not a line per routed connection.
            if (!verbose && shown.index < NovaLogLevel.warn.index) continue;
            NovaLog.instance.writeCore(message, level: shown);
          }
        }
      case 'state':
        final ProxyConnectionState prev = _state;
        _state = ProxyConnectionState.values.firstWhere(
          (s) => s.name == event['value'],
          orElse: () => _state,
        );
        if (_state != prev) NovaLog.instance.write('State: ${_state.name}');
        // Any settled state clears the connect watchdog.
        if (_state != ProxyConnectionState.connecting) {
          _watchdog?.cancel();
          _watchdog = null;
        }
        if (_state != ProxyConnectionState.disconnecting) {
          _stopWatchdog?.cancel();
          _stopWatchdog = null;
        }
        // The core's per-node latency only means anything while the tunnel is up;
        // drop it the moment we leave connected so a stale ping can't linger on
        // the list after disconnect.
        if (_state != ProxyConnectionState.connected &&
            !coreHealth.value.isEmpty) {
          coreHealth.value = CoreNodeHealth.empty;
        }
        notifyListeners();
        // Just came up: verify real traffic actually flows. A manually pinned
        // exit fails over to the fastest live server; an auto (subscription)
        // exit whose urltest pool led with a dead node gets one clean rebuild.
        if (_state == ProxyConnectionState.connected &&
            prev != ProxyConnectionState.connected) {
          if (_active?.pinnedNode != null) {
            unawaited(_verifyPinnedConnectivity());
          } else if (_active?.isSubscription ?? false) {
            unawaited(_verifyAutoConnectivity());
          }
        }
      case 'traffic':
        _traffic = TrafficStats(
          uplinkBps: (event['up'] as num?)?.toDouble() ?? 0,
          downlinkBps: (event['down'] as num?)?.toDouble() ?? 0,
          uplinkTotal: (event['upTotal'] as num?)?.toInt() ?? 0,
          downlinkTotal: (event['downTotal'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
      case 'groups':
        _onGroups(event['groups']);
      case 'error':
        _lastError = event['message'] as String?;
        NovaLog.instance
            .write('Error: $_lastError', level: NovaLogLevel.error);
        _state = ProxyConnectionState.error;
        notifyListeners();
        // A rule-set that failed to read at startup is transient (the file is
        // complete on disk); one automatic retry beats showing the user an
        // error they can only answer by tapping connect again.
        final String msg = (_lastError ?? '').toLowerCase();
        if (msg.contains('rule-set') && msg.contains('eof') && !_ruleSetRetried) {
          _ruleSetRetried = true;
          NovaLog.instance.write('Rule-set read failed at startup; retrying once');
          unawaited(Future<void>.delayed(
              const Duration(milliseconds: 400), connect));
        }
    }
  }

  /// Translates the core's outbound-group snapshot into [coreHealth]. The host
  /// sends `{ "type": "groups", "groups": [ { "tag": "proxy", "selected":
  /// "node-3", "items": [ { "tag": "node-0", "delay": 217 }, ... ] } ] }`, where
  /// `delay` is the urltest round-trip in ms (0 = failed/untested). We keep only
  /// the auto-select group (`proxy`) and map its `node-i` tags back to real
  /// nodes via [_coreTagKeys], so the server list can show a live, honest ping
  /// for the very nodes that can't be probed from outside the tunnel.
  void _onGroups(Object? raw) {
    // No mapping means a single/pinned node with no urltest group; nothing to
    // attribute the numbers to.
    if (_coreTagKeys.isEmpty) return;
    CoreNodeHealth next = parseCoreGroups(_coreTagKeys, raw);
    if (measuring.value) {
      // Mid-measure: the measuring group's own pick is not "carrying traffic"
      // (nothing is connected), and a node that has not answered yet is
      // pending, not "no response". Final verdicts land in measureNodes().
      next = CoreNodeHealth(
          delayMsByKey: next.delayMsByKey,
          testedKeys: next.delayMsByKey.keys.toSet());
    }
    final CoreNodeHealth cur = coreHealth.value;
    if (next.selectedKey == cur.selectedKey &&
        mapEquals(next.delayMsByKey, cur.delayMsByKey) &&
        setEquals(next.testedKeys, cur.testedKeys)) {
      return;
    }
    coreHealth.value = next;
  }

  /// Turns the host's `groups` payload into a [CoreNodeHealth], mapping the
  /// config's `node-i` outbound tags back to real node keys with [tagKeys].
  ///
  /// Public because it is the fiddly part and is shared: the desktop
  /// controller reshapes the Clash API's `/proxies` history into this same
  /// payload so both hosts use one parser. It drops 0-delay items (the core's
  /// "no successful test yet"), keeps only the auto-select group `proxy`, and
  /// ignores tags it has no mapping for.
  static CoreNodeHealth parseCoreGroups(
      Map<String, String> tagKeys, Object? raw) {
    if (raw is! List) return CoreNodeHealth.empty;
    final Map<String, int> delays = <String, int>{};
    final Set<String> tested = <String>{};
    String? selectedKey;
    for (final Object? g in raw) {
      if (g is! Map) continue;
      // The auto-selector is tagged `proxy`; ignore any other group the core
      // might expose so a selector's own entry can't shadow the urltest figures.
      if (g['tag'] != 'proxy') continue;
      final Object? sel = g['selected'];
      if (sel is String) selectedKey = tagKeys[sel];
      final Object? items = g['items'];
      if (items is List) {
        for (final Object? it in items) {
          if (it is! Map) continue;
          final Object? tag = it['tag'];
          final int delay = (it['delay'] as num?)?.toInt() ?? 0;
          final String? key = tag is String ? tagKeys[tag] : null;
          if (key == null) continue;
          // The node is in the pool, so the core is measuring it: record that
          // even when it has not answered, so the UI can say "no response"
          // (tried, failed) rather than the misleading "not testable".
          tested.add(key);
          // A 0 delay is "no successful measurement", not a latency we can
          // honestly show as a number, so it stays out of the delay map.
          if (delay > 0) delays[key] = delay;
        }
      }
    }
    return CoreNodeHealth(
        delayMsByKey: delays, testedKeys: tested, selectedKey: selectedKey);
  }

  @override
  void selectProfile(ProxyProfile? profile) {
    _active = profile;
    notifyListeners();
  }

  // ---- "test all through the core": the measuring core (Android host) ----

  // Android hosts NovaMeasure (a second libbox service with no TUN). iOS runs
  // its core inside the Network Extension, so a tunnel-less measuring core
  // there is a separate piece of work; the button stays hidden until then.
  @override
  bool get canMeasureNodes => Platform.isAndroid || _measureForTest;

  /// Tests run on a desktop VM where [Platform.isAndroid] is false; this lets
  /// the Android measuring path be exercised there.
  static bool _measureForTest = false;
  @visibleForTesting
  static bool get measureSupportedForTest => true;
  @visibleForTesting
  static set measureForTest(bool v) => _measureForTest = v;

  @visibleForTesting
  void debugSetStateForTest(ProxyConnectionState s) {
    _state = s;
  }

  @override
  Future<String?> measureNodes(List<ProxyNode> nodes) async {
    if (!canMeasureNodes || measuring.value || nodes.isEmpty) return null;
    if (_state != ProxyConnectionState.disconnected &&
        _state != ProxyConnectionState.error) {
      return 'Disconnect first to measure all servers.';
    }
    measuring.value = true;
    try {
      final List<ProxyNode> resolved = await _resolveEndpointHosts(nodes);
      // Same rule-set source as the tunnel: the bundled .srs on disk. The
      // default would fetch them from GitHub at startup, which is blocked in
      // Iran, and the measuring core would never come up.
      final SingboxRouteOptions opts = routeOptions.copyWith(
          hardenTls: _active?.hardenTls ?? false,
          localRuleSets: Platform.isAndroid);
      // xhttp nodes run on the Xray core, reached by the measuring core as
      // local socks exits, exactly as the tunnel's auto pool does. Without
      // this they read "not testable" even though they connect.
      final bool xhttpPool = kXrayXhttpEnabled && Platform.isAndroid;
      String? xrayJson;
      if (xhttpPool) {
        final List<ProxyNode> xhttpNodes = SingboxConfig.pickedXhttpNodes(
            resolved,
            options: opts,
            poolCap: SingboxConfig.kMeasurePoolCap);
        if (xhttpNodes.isNotEmpty) {
          final List<ProxyNode> resolvedX = <ProxyNode>[
            for (final ProxyNode x in xhttpNodes) await _resolveXhttpServer(x),
          ];
          xrayJson = XrayConfig.buildMulti(resolvedX,
              basePort: XrayConfig.defaultSocksPort);
        }
      }
      final ({Map<String, dynamic> config, Map<String, String> tagKeys}) built =
          SingboxConfig.buildMeasureMap(resolved,
              options: opts,
              mixedPort: 0,
              includeXhttp: xrayJson != null,
              xhttpBasePort: XrayConfig.defaultSocksPort);
      // Live updates arrive as `groups` events; map them with the measuring
      // run's tags for as long as it runs.
      _coreTagKeys = built.tagKeys;
      coreHealth.value = CoreNodeHealth.empty;
      NovaLog.instance
          .write('Measuring ${built.tagKeys.length} servers through the core');
      String configJson = jsonEncode(built.config);
      if (Platform.isAndroid) {
        final String base = await _extractRuleSets();
        configJson = configJson.replaceAll(SingboxConfig.ruleSetBaseToken, base);
      }
      final Object? raw = await _control.invokeMethod<Object?>('measure',
          <String, dynamic>{
            'configJson': configJson,
            'tags': built.tagKeys.keys.toList(),
            if (xrayJson != null) 'xrayConfigJson': xrayJson,
          }).timeout(const Duration(seconds: 90));
      final Map<String, int> delays = <String, int>{};
      if (raw is Map) {
        raw.forEach((Object? tag, Object? ms) {
          final String? key = tag is String ? built.tagKeys[tag] : null;
          if (key != null && ms is num && ms > 0) delays[key] = ms.toInt();
        });
      }
      // Final verdicts: every node in the pool was tried.
      coreHealth.value = CoreNodeHealth(
          delayMsByKey: delays, testedKeys: built.tagKeys.values.toSet());
      NovaLog.instance.write(
          'Measured ${built.tagKeys.length} servers through the core: '
          '${delays.length} answered');
      return null;
    } on FormatException catch (e) {
      return e.message;
    } on PlatformException catch (e) {
      return e.message ?? 'Could not measure';
    } catch (e) {
      return 'Could not measure: $e';
    } finally {
      _coreTagKeys = const <String, String>{};
      measuring.value = false;
    }
  }

  /// Re-reads the real tunnel state from the platform. Called on app resume so
  /// the UI reflects a tunnel that's still running (the event stream only fires
  /// on *changes*, so a relaunched app would otherwise show "disconnected").
  @override
  Future<void> syncStatus() async {
    try {
      final String? name = await _control.invokeMethod<String>('status');
      if (name == null) return;
      final ProxyConnectionState s = ProxyConnectionState.values.firstWhere(
        (ProxyConnectionState s) => s.name == name,
        orElse: () => _state,
      );
      if (s != _state) {
        _state = s;
        if (s != ProxyConnectionState.connecting) {
          _watchdog?.cancel();
          _watchdog = null;
        }
        notifyListeners();
      }
    } catch (_) {
      // Best-effort; leave the current state untouched on failure.
    }
  }

  @override
  Future<void> connect() async {
    final ProxyProfile? profile = _active;
    if (profile == null) {
      _lastError = 'No profile selected';
      _state = ProxyConnectionState.error;
      notifyListeners();
      return;
    }
    // A fresh user-initiated connect re-arms the one-shot auto self-heal; the
    // heal's own reconnect keeps [_autoHealTried] set (via [_healing]) so it
    // can't loop.
    if (!_healing) _autoHealTried = false;
    exitUnreachable = false;
    final int seq = ++_opSeq;
    _stopWatchdog?.cancel();
    _stopWatchdog = null;
    _state = ProxyConnectionState.connecting;
    _lastError = null;
    NovaLog.instance.write(
      'Connecting with "${profile.name}" '
      '(${profile.pinnedNode != null ? 'server chosen by you' : 'auto-select'}'
      '${profile.hardenTls ? ', SNI-block bypass on' : ''})',
    );
    notifyListeners();

    final String config;
    try {
      config = await _buildSingboxConfig(profile);
    } on FormatException catch (e) {
      _lastError = e.message;
      _state = ProxyConnectionState.error;
      notifyListeners();
      return;
    } catch (e) {
      _lastError = _subscriptionErrorMessage(e);
      _state = ProxyConnectionState.error;
      notifyListeners();
      return;
    }

    // Resolving a subscription can take seconds. If the user moved on in that
    // time (switched server, toggled the bypass, disconnected), a newer request
    // owns the tunnel now; starting this one would put a stale server up
    // underneath it and leave the UI on "connecting" with nothing to wait for.
    if (seq != _opSeq) {
      NovaLog.instance.write('Connect superseded by a newer request; skipped');
      return;
    }

    // An AmneziaWG config handed to a core built without it produces a tunnel
    // that comes up and carries nothing, which reads as a broken server. Ask
    // the core first and say what is actually wrong. An unmeasurable host
    // leaves the verdict unknown and the connect proceeds unchanged.
    if (CoreFeatures.usesAwg(config)) {
      await _features.load();
      if (seq != _opSeq) return;
      if (_features.awgUnsupported) {
        _lastError = _features.awgUnsupportedMessage;
        _state = ProxyConnectionState.error;
        notifyListeners();
        return;
      }
    }

    try {
      final Map<String, Uint8List>? ruleSets =
          Platform.isIOS ? await _leanRuleSets() : null;
      if (seq != _opSeq) return;
      await _control.invokeMethod<void>('start', <String, dynamic>{
        'configJson': config,
        // Shown in the platform's ongoing VPN notification. Cosmetic only.
        if (_active?.name != null) 'label': _active!.name,
        // For an xhttp node, the Xray core config the host runs alongside the
        // sing-box bridge (Android only for now).
        if (_pendingXrayConfig != null) 'xrayConfigJson': _pendingXrayConfig,
        // Bundled rule-set files the lean iOS config references as local
        // rule-sets. The host writes them next to the config in the App Group.
        if (ruleSets != null) 'ruleSets': ruleSets,
      });
      _armWatchdog();
    } catch (e) {
      _lastError = e is PlatformException ? e.message : e.toString();
      _state = ProxyConnectionState.error;
      notifyListeners();
    }
  }

  /// Turns a subscription-fetch failure into something the user can act on. A
  /// timeout or socket error almost always means the subscription URL is being
  /// filtered on this network (common in Iran, where the worker's *.workers.dev
  /// domain is blocked), not that the config itself is broken.
  String _subscriptionErrorMessage(Object e) {
    final String s = e.toString().toLowerCase();
    final bool networky = s.contains('timed out') ||
        s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        s.contains('connection');
    if (networky) {
      return "Couldn't reach your subscription. This network may be blocking "
          'it (common in Iran). Try mobile data or another network, or connect '
          'through a working config first, then refresh.';
    }
    return 'Could not load subscription: $e';
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_connectTimeout, () {
      if (_state == ProxyConnectionState.connecting) {
        _lastError = 'The tunnel did not come up in time. The server may be '
            'unreachable, try another config or scan a clean IP in Radar.';
        _state = ProxyConnectionState.error;
        notifyListeners();
      }
    });
  }

  @override
  Future<void> disconnect() async {
    _watchdog?.cancel();
    _watchdog = null;
    // Invalidate any connect() still resolving its config: it must not send
    // `start` after this stop.
    ++_opSeq;
    // A real user disconnect clears the heal guard so the next session can heal
    // again; the heal's own reconnect (which disconnects first) must not.
    if (!_healing) _autoHealTried = false;
    exitUnreachable = false;
    _state = ProxyConnectionState.disconnecting;
    notifyListeners();
    try {
      await _control.invokeMethod<void>('stop');
      // The host answers a stop with a `disconnected` state event (Android
      // even when nothing was running). If it never comes, the app must not sit
      // on "disconnecting" forever: settle it, so the user can connect again.
      _stopWatchdog?.cancel();
      _stopWatchdog = Timer(const Duration(seconds: 6), () {
        if (_state == ProxyConnectionState.disconnecting) {
          NovaLog.instance.write(
              'Stop was not acknowledged by the host; treating as disconnected',
              level: NovaLogLevel.warn);
          _state = ProxyConnectionState.disconnected;
          notifyListeners();
        }
      });
    } catch (e) {
      _lastError = e is PlatformException ? e.message : e.toString();
      _state = ProxyConnectionState.error;
      notifyListeners();
    }
  }

  /// Translates a [ProxyProfile] into a sing-box config document: parse the
  /// share link into a [ProxyNode], then build the full config (TUN inbound,
  /// DNS, per-protocol outbound, rule-based routing). A profile that already
  /// holds a full sing-box JSON config is passed through unchanged.
  ///
  /// Throws [FormatException] when the link can't be parsed.
  Future<String> _buildSingboxConfig(ProxyProfile profile) async {
    final String trimmed = profile.uri.trim();
    if (profile.kind == ProxyKind.singboxConfig || trimmed.startsWith('{')) {
      return trimmed;
    }
    // Resolves single links directly and subscriptions by fetching + expanding
    // them, so a subscription profile (empty uri, URL in subscriptionUrl) can
    // actually connect instead of failing as an "invalid profile link". A
    // subscription returns its whole node list so the core auto-picks the
    // fastest via a urltest; a single link is just the one node.
    List<ProxyNode> nodes =
        await resolveProfileNodes(profile, fetch: subFetcher);
    if (nodes.isEmpty) {
      throw FormatException(emptyResolveMessage(profile));
    }
    // AmneziaWG's core parses the peer Endpoint with ParseAddr and rejects a
    // hostname outright ("IPC error -22 ... unexpected character"), so a config
    // whose Endpoint is a domain never connects. Resolve any endpoint node's
    // host to a numeric IP before the core sees it. Best-effort: if it does not
    // resolve, the original config is kept (no worse than today).
    nodes = await _resolveEndpointHosts(nodes);
    // Remember each node's own name (the label the panel gave it) keyed by its
    // stable key, so the dashboard can show "Connected via <name>" instead of a
    // bare address, which for a clean-IP node is a meaningless Cloudflare IP.
    _keyToName = <String, String>{
      for (final ProxyNode n in nodes) proxyNodeKey(n): n.tag,
    };
    // Honour a manually pinned exit node: route through just that one instead of
    // letting the urltest auto-pick. Falls back to auto if it's no longer in the
    // subscription.
    final String? pin = profile.pinnedNode;
    if (pin != null) {
      bool honoured = false;
      // Match the pinned node by its stable key first; if the panel rotated its
      // clean IP so no key matches, fall back to the name the user pinned, which
      // survives the rotation. Without this the pin silently breaks on every
      // refresh and the user lands on a different (often different-country) exit.
      final String? pinName = profile.pinnedName;
      ProxyNode? chosen;
      for (final ProxyNode n in nodes) {
        if (proxyNodeMatchesKey(n, pin)) {
          chosen = n;
          break;
        }
      }
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
        // sing-box has no xhttp transport, so an xhttp pin can only be honoured
        // on Android, where the two-core path runs it on Xray. Elsewhere it stays
        // unbuildable, so treat it like a pin gone from the subscription and fall
        // through to auto rather than leaving the profile unconnectable.
        final bool xhttpOk = chosen.network != 'xhttp' ||
            (kXrayXhttpEnabled && (Platform.isAndroid || Platform.isIOS));
        if (xhttpOk) {
          nodes = <ProxyNode>[chosen];
          honoured = true;
          NovaLog.instance.write(
              'Using your chosen server ${chosen.server}:${chosen.port} '
              '(${chosen.protocol.label})');
        }
      }
      // The pinned server is gone from the subscription (a panel rotating its
      // clean IPs changes the address, which changes the key). Auto-select is the
      // only thing left to do, but say so: connecting through a different server
      // than the one the list shows as selected must never be silent.
      if (!honoured) {
        NovaLog.instance.write(
          'The server you chose is no longer in this subscription; '
          'auto-selecting instead',
          level: NovaLogLevel.warn,
        );
        notice.value = ProxyNotice.pinnedExitGone;
      }
    } else if (profile.fastNodes.isNotEmpty) {
      // Auto-select: front-load the nodes the picker measured as fastest so the
      // urltest pool (which takes the first N) is built from good exits, not the
      // subscription's arbitrary first few.
      final Map<String, int> rank = <String, int>{
        for (int i = 0; i < profile.fastNodes.length; i++)
          profile.fastNodes[i]: i,
      };
      nodes = <ProxyNode>[...nodes]..sort((ProxyNode a, ProxyNode b) {
          int nodeRank(ProxyNode node) =>
              rank[proxyNodeKey(node)] ??
              rank['${node.server}:${node.port}'] ??
              1 << 30;
          final int ra = nodeRank(a);
          final int rb = nodeRank(b);
          return ra.compareTo(rb);
        });
    } else if (nodes.length > 1) {
      // First connect with no measured nodes yet: quickly ping-rank a sample so
      // Auto doesn't land on a dead/slow exit (which shows up as "connected but
      // no internet / no country"). This is the ONE cost the first connect pays
      // that later connects skip (they reuse profile.fastNodes), so it is the
      // reason a first connect feels slow. Hard-cap the whole rank so the tunnel
      // never waits on it: on a slow or censored network the probes can stack up,
      // and the core's own urltest re-picks the fastest exit within seconds after
      // connect regardless. If the cap is hit we start with the order we have;
      // pickedMultiNodes already puts clean-IP exits first when the bypass is on.
      nodes = await _rankByPing(nodes).timeout(
        const Duration(milliseconds: 1300),
        onTimeout: () => nodes,
      );
    }
    // iOS runs the core inside a Network Extension with a hard ~50 MB memory
    // cap, so build a lean config there (fewer nodes, normal MTU, rule-sets fed
    // in as bytes) to keep the extension from being OOM-killed mid-connection.
    //
    // Android keeps the full config but must use BUNDLED (local) rule-sets: the
    // remote-rule-set path downloads geosite/geoip .srs from raw.githubusercontent
    // .com on connect, which fails during tunnel bring-up ("no available network
    // interface") and is blocked outright in Iran, so the core never starts. The
    // core shares this app's sandbox, so we extract the .srs to disk and point the
    // config's path token at them, exactly like the desktop core does.
    final SingboxRouteOptions opts = routeOptions.copyWith(
      lean: Platform.isIOS,
      localRuleSets: Platform.isAndroid,
      // The SNI-block bypass, per profile: turned on by the self-heal below or
      // by the user, applied only to clean-IP fronted nodes. The three overrides
      // are the user's edits from the bypass editor (null = field-tested default).
      hardenTls: profile.hardenTls,
      bypassFingerprint: profile.bypassFingerprint,
      bypassCipherSuites: profile.bypassCipherSuites,
      bypassFragmentMask: profile.bypassFragmentMask,
      // Android's VpnService uses the gvisor stack (userspace TCP, clamped MSS),
      // like iOS. The system stack forwards raw IP and doesn't clamp MSS, which
      // the code comment on the inbound documents as dropping large packets on a
      // constrained full-device TUN. Desktop keeps the system stack (its host
      // clamps fine). tlsFragment stays ON (Iran anti-DPI).
      gvisorStack: Platform.isAndroid,
    );
    // Per-ISP optimization: detect the phone's carrier and fold in the DPI-best
    // uTLS fingerprint + fragmentation for it. Best-effort and time-boxed - any
    // failure leaves `opts` as-is (each node keeps its own fingerprint), so a
    // connect is never blocked on this.
    SingboxRouteOptions tuned = opts;
    if (opts.autoOptimizeCarrier) {
      try {
        final IspMatch m = await IspOptimizer.instance
            .resolve(enabled: true, host: nodes.first.server)
            .timeout(const Duration(seconds: 8));
        // Only a specific carrier match may flip fragmentation (that is a
        // deliberate per-carrier choice). For an unknown carrier or Wi-Fi we keep
        // the app's fragment-on default so anti-DPI never silently regresses; we
        // still apply the fingerprint (its default is Chrome, same as today).
        // A user's manual fingerprint (already in opts.fingerprintOverride) wins
        // over the carrier profile; otherwise take the carrier's pick.
        final bool manual = (opts.fingerprintOverride ?? '').isNotEmpty;
        tuned = opts.copyWith(
          fingerprintOverride:
              manual ? opts.fingerprintOverride : m.fingerprint,
          tlsFragment: m.source == 'carrier'
              ? (m.tlsFragment ?? opts.tlsFragment)
              : opts.tlsFragment,
        );
        NovaLog.instance.write(
          'Carrier profile: ${m.source} -> fingerprint '
          '${tuned.fingerprintOverride ?? 'default'}, '
          'fragmentation ${tuned.tlsFragment ? 'on' : 'off'}',
        );
      } catch (e) {
        NovaLog.instance.write(
          'Carrier profile unavailable, keeping the current settings ($e)',
          level: NovaLogLevel.warn,
        );
        tuned = opts;
      }
    }
    // xhttp is an Xray-only transport. When the combined sing-box+Xray core is
    // present (Android/iOS today), xhttp nodes run on Xray and sing-box reaches
    // them through a local Xray socks inbound, both for a single/pinned node and
    // inside the auto-select pool. Desktop has no Xray binding yet, so it keeps
    // dropping xhttp. See docs/xray-core-scope.md.
    final bool xhttpPool =
        kXrayXhttpEnabled && (Platform.isAndroid || Platform.isIOS);
    // Remember which real node each `node-i` tag maps to, so the core's per-node
    // urltest results (which come back keyed by those tags) can be shown against
    // the right server in the list. Only a real multi-node pool has a urltest
    // group; a single/pinned node has none. Include xhttp in the mapping when the
    // pool carries it, so its socks-wrapped node-i tag maps to the right server.
    if (nodes.length == 1) {
      _coreTagKeys = const <String, String>{};
    } else {
      final List<String> keys = SingboxConfig.orderedMultiNodeKeys(nodes,
          options: tuned, includeXhttp: xhttpPool);
      _coreTagKeys = <String, String>{
        for (int i = 0; i < keys.length; i++) 'node-$i': keys[i],
      };
    }
    _pendingXrayConfig = null;

    // Single/pinned xhttp node: sing-box gets the TUN->SOCKS bridge, Xray gets
    // the real xhttp config on one local socks port.
    if (xhttpPool && nodes.length == 1 && nodes.first.network == 'xhttp') {
      const int socksPort = XrayConfig.defaultSocksPort;
      final ProxyNode xNode = await _resolveXhttpServer(nodes.first);
      _pendingXrayConfig = XrayConfig.build(xNode, socksPort: socksPort);
      NovaLog.instance.write(
          'xhttp node: running it on the Xray core, sing-box bridges the TUN.');
      final String bridge =
          SingboxConfig.buildXraySocksBridge(socksPort, options: tuned);
      // Android resolves the rule-set token to an on-disk path here; iOS returns
      // the token untouched and the host replaces it (rule-sets are passed as
      // bytes in the `start` call), exactly like the normal single-node path.
      if (Platform.isAndroid) {
        final String base = await _extractRuleSets();
        return bridge.replaceAll(SingboxConfig.ruleSetBaseToken, base);
      }
      return bridge;
    }

    // Auto pool that contains xhttp nodes: Xray serves one socks inbound per
    // xhttp node (ports from XrayConfig.defaultSocksPort up), and the sing-box
    // urltest lists each of those as an ordinary socks outbound alongside the
    // real exits. The two lists share pickedXhttpNodes' order so the ports line
    // up. That also gives every xhttp node a live ping and a pick through the
    // existing command surface, no separate Xray stats channel.
    if (xhttpPool && nodes.length > 1) {
      final List<ProxyNode> xhttpNodes =
          SingboxConfig.pickedXhttpNodes(nodes, options: tuned);
      if (xhttpNodes.isNotEmpty) {
        const int base = XrayConfig.defaultSocksPort;
        final List<ProxyNode> resolvedX = <ProxyNode>[
          for (final ProxyNode x in xhttpNodes) await _resolveXhttpServer(x),
        ];
        _pendingXrayConfig = XrayConfig.buildMulti(resolvedX, basePort: base);
        NovaLog.instance.write(
            'Auto pool includes ${xhttpNodes.length} xhttp node(s) on the Xray '
            'core; sing-box measures them as local socks exits.');
        final String multi = SingboxConfig.buildMulti(nodes,
            options: tuned, includeXhttp: true, xhttpBasePort: base);
        if (Platform.isAndroid) {
          final String ruleBase = await _extractRuleSets();
          return multi.replaceAll(SingboxConfig.ruleSetBaseToken, ruleBase);
        }
        return multi;
      }
    }

    final String config = nodes.length == 1
        ? SingboxConfig.build(nodes.first, options: tuned)
        : SingboxConfig.buildMulti(nodes, options: tuned);
    if (Platform.isAndroid) {
      final String base = await _extractRuleSets();
      return config.replaceAll(SingboxConfig.ruleSetBaseToken, base);
    }
    return config;
  }

  /// Writes the bundled `.srs` rule-sets into the app-support dir (once) and
  /// returns their directory, so the Android core can load them from disk
  /// instead of fetching them over the (blocked) network. Only the two shipped
  /// sets (geosite-ir, geosite-ads) are extracted; that's what [localRuleSets]
  /// references.
  Future<String> _extractRuleSets() async {
    // Serialised: two connects racing through here (a fast server switch right
    // after a fresh install) must not both write. And each write is atomic
    // (temp file + rename): a core that opens the file mid-write would read a
    // truncated stream and die with "parse rule-set: unexpected EOF", which
    // was seen once on the first switch after a fresh install.
    return _ruleSetLock.synchronized(() async {
      final Directory dir = await getApplicationSupportDirectory();
      for (final String file in <String>[
        SingboxConfig.kGeositeIrFile,
        SingboxConfig.kGeositeAdsFile,
      ]) {
        final File out = File('${dir.path}/$file');
        final ByteData data = await rootBundle.load('assets/rulesets/$file');
        final int len = data.lengthInBytes;
        if (out.existsSync() && out.lengthSync() == len) continue;
        final File tmp = File('${dir.path}/$file.tmp');
        await tmp.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, len),
          flush: true,
        );
        await tmp.rename(out.path);
      }
      return dir.path.replaceAll(r'\', '/');
    });
  }

  final _AsyncLock _ruleSetLock = _AsyncLock();

  /// After coming up on a manually pinned exit, confirm the exit really carries
  /// traffic. A pinned node builds a single-outbound config, so a dead exit still
  /// "connects" (Cloudflare's anycast IP accepts the TCP handshake) while nothing
  /// actually loads.
  ///
  /// A pin is the user's explicit choice, so a failed probe **reports** and does
  /// not switch. Nova used to clear the pin here and let the urltest auto-pick
  /// another node, which meant the config the Servers list showed as selected was
  /// not the one carrying traffic, i.e. the app silently overriding the user. It
  /// fired on a false negative (the probe endpoint being unreachable for its own
  /// reasons), throwing away a working choice. Now the pin stands, the dashboard
  /// says the exit is not passing traffic, and switching stays a tap away.
  Future<void> _verifyPinnedConnectivity() async {
    final ProxyProfile? profile = _active;
    if (profile == null || profile.pinnedNode == null) return;
    // Let the tunnel settle before probing.
    await Future<void>.delayed(const Duration(seconds: 3));
    // Bail if the user disconnected or switched away in the meantime.
    if (_state != ProxyConnectionState.connected ||
        _active?.pinnedNode != profile.pinnedNode) {
      return;
    }
    // Retry a few times before calling it: a tunnel that has just come up can
    // need a couple of seconds more than the settle delay, and one missed probe
    // is not evidence the exit is dead.
    for (int attempt = 0; attempt < 3; attempt++) {
      if (await _probeInternet()) {
        if (exitUnreachable) {
          exitUnreachable = false;
          notifyListeners();
        }
        return; // exit is healthy
      }
      if (_state != ProxyConnectionState.connected ||
          _active?.pinnedNode != profile.pinnedNode) {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (_state != ProxyConnectionState.connected ||
        _active?.pinnedNode != profile.pinnedNode) {
      return;
    }
    // A pinned clean-IP node that carries nothing gets the same one-shot
    // escalation as auto: the pin is kept, only the TLS profile changes.
    if (!_autoHealTried) {
      _autoHealTried = true;
      _healing = true;
      try {
        if (await _escalateToBypass(profile, 'your chosen server carried no '
            'traffic')) {
          return;
        }
      } finally {
        _healing = false;
      }
    }
    NovaLog.instance.write(
      'The server you chose connected but carried no traffic. Keeping your '
      'choice; switch server or use Auto to change it.',
      level: NovaLogLevel.warn,
    );
    exitUnreachable = true;
    notice.value = ProxyNotice.pinnedExitNoTraffic;
    notifyListeners();
  }

  /// After an auto (subscription) tunnel comes up, confirm traffic really flows.
  /// A multi-node profile builds a `urltest` outbound: the core health-checks the
  /// pool and settles on a live node, but the *initial* pick can be a dead exit,
  /// so the orb goes green while nothing loads (the exact "connected but no
  /// internet" report). We probe for a while first — urltest usually self-corrects
  /// within a few cycles, no rebuild needed — and only if it never gets through do
  /// we rebuild the tunnel ONCE, which re-resolves the pool and restarts urltest
  /// from scratch. Guarded by [_autoHealTried] so a genuinely dead subscription
  /// can't loop; the honest "Verifying…" subtitle keeps the UI truthful meanwhile.
  Future<void> _verifyAutoConnectivity() async {
    final ProxyProfile? profile = _active;
    if (profile == null ||
        !profile.isSubscription ||
        profile.pinnedNode != null) {
      return;
    }
    // Probe periodically over ~18s, giving urltest time to converge on a live
    // node before we consider a heavier rebuild.
    for (int attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      // Bail if the user disconnected, switched profile, or pinned in between.
      if (_state != ProxyConnectionState.connected ||
          _active?.id != profile.id ||
          _active?.pinnedNode != null) {
        return;
      }
      if (await _probeInternet()) {
        // Traffic flows. Clear a stale failure verdict (a late-converging
        // urltest can recover after we already gave up) so the dashboard goes
        // back to "Secure" instead of staying on the failure message.
        if (exitUnreachable) {
          exitUnreachable = false;
          notifyListeners();
        }
        return;
      }
    }
    // Still nothing after ~18s. Rebuild the tunnel once (fresh pool + fresh
    // urltest) unless we've already tried this session; if we have, stop
    // pretending to verify and say so, once.
    if (_autoHealTried) {
      if (!exitUnreachable) {
        NovaLog.instance.write(
          'The tunnel is up but nothing is getting through, and the one '
          'rebuild did not help.',
          level: NovaLogLevel.error,
        );
        exitUnreachable = true;
        notice.value = ProxyNotice.tunnelHasNoInternet;
        notifyListeners();
      }
      return;
    }
    _autoHealTried = true;
    _healing = true;
    try {
      // The one rebuild is spent on the SNI-block bypass when the subscription
      // is the kind it helps: clean-IP fronted worker nodes, none of which
      // carried traffic. That is the signature of a network blocking the
      // worker's SNI, and a plain rebuild would only replay the same handshake.
      // The switch is persisted so the next connect starts hardened, and the
      // user is told; they can turn it off in the node list.
      if (await _escalateToBypass(profile, 'no traffic on any server')) {
        return; // _escalateToBypass reconnected
      }
      NovaLog.instance.write(
        'No traffic after ~18s on auto-select; rebuilding the tunnel once.',
        level: NovaLogLevel.warn,
      );
      await reconnect();
    } finally {
      _healing = false;
    }
  }

  /// Turn on the SNI-block bypass for [profile] and reconnect, if the profile
  /// is not already hardened and actually contains clean-IP fronted nodes for
  /// it to act on. Returns false when there was nothing to escalate to.
  Future<bool> _escalateToBypass(ProxyProfile profile, String because) async {
    if (profile.hardenTls) return false;
    List<ProxyNode> nodes;
    try {
      nodes = await resolveProfileNodes(profile, fetch: subFetcher);
    } catch (_) {
      return false;
    }
    if (!nodes.any((ProxyNode n) => n.isCleanIpFronted)) return false;
    final ProxyProfile hardened = profile.copyWith(hardenTls: true);
    _active = hardened;
    await persistProfile?.call(hardened);
    NovaLog.instance.write(
      'Turning on the SNI-block bypass for "${profile.name}" ($because): '
      'Go TLS with the PattNG cipher list, TLS-record and TCP fragmentation, '
      'on its clean-IP servers.',
      level: NovaLogLevel.warn,
    );
    notice.value = ProxyNotice.sniBypassOn;
    await reconnect();
    return true;
  }

  /// Fetches a tiny reliability endpoint. On mobile the core runs as a full
  /// device TUN, so the app's own request egresses through the tunnel: a
  /// reachable 204 means the exit genuinely works, a timeout means it's dead.
  Future<bool> _probeInternet() async {
    // NON-Cloudflare 204 endpoints on purpose: the Nova exit is usually a
    // Cloudflare Worker, and a Worker can't relay to Cloudflare's own hosts
    // (loop protection), so cp.cloudflare.com always fails through the tunnel and
    // made this health check read every pinned exit as dead. gstatic/google are
    // off-Cloudflare and resolve to the working v4 path. Mirrors ConnInfo._probe.
    const List<String> urls = <String>[
      'https://www.gstatic.com/generate_204',
      'https://connectivitycheck.gstatic.com/generate_204',
      'https://www.google.com/generate_204',
    ];
    for (int attempt = 0; attempt < 2; attempt++) {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
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

  /// Loads the bundled `.srs` rule-sets the lean iOS config references, keyed by
  /// the filename the host writes into the App Group. Best-effort per file: a
  /// missing asset is skipped rather than aborting the connection.
  Future<Map<String, Uint8List>> _leanRuleSets() async {
    final Map<String, Uint8List> out = <String, Uint8List>{};
    for (final MapEntry<String, String> e
        in SingboxConfig.leanRuleSetAssets.entries) {
      try {
        final ByteData data = await rootBundle.load(e.key);
        out[e.value] =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        // Asset unavailable — skip; the rule-set simply won't apply.
      }
    }
    return out;
  }

  /// TCP-pings a sample of nodes (direct, since this runs before the tunnel is
  /// up) and returns them ordered fastest-first, with unreachable ones last. So
  /// the urltest's pool — the first N — is built from good exits.
  /// Rewrites any AmneziaWG/WireGuard endpoint node whose peer Endpoint is a
  /// domain to use a resolved IP, since the AmneziaWG core cannot parse a
  /// hostname endpoint. Non-endpoint nodes and already-numeric endpoints pass
  /// through untouched.
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
        out.add(n); // no endpoint, or already an IP literal
        continue;
      }
      final String? ip = await _resolveHostToIp(host);
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

  /// An xhttp node with its server host resolved to an IP. Xray runs the xhttp
  /// node and dials this server itself; with a hostname it would need DNS that is
  /// not up yet (the Xray log fills with "dns: exchange failed for the server"),
  /// so it must be numeric. SNI and Host stay the domain (copyWith keeps sni and
  /// wsHost), so TLS and the xhttp Host header are unchanged. Already-numeric or
  /// unresolvable servers pass through untouched.
  Future<ProxyNode> _resolveXhttpServer(ProxyNode n) async {
    if (InternetAddress.tryParse(n.server) != null) return n;
    final String? ip = await _resolveHostToIp(n.server);
    if (ip == null) {
      NovaLog.instance.write(
        'xhttp server ${n.server} did not resolve; Xray may fail to reach it',
        level: NovaLogLevel.warn,
      );
      return n;
    }
    NovaLog.instance.write(
        'xhttp server ${n.server} -> $ip (Xray needs an IP; SNI/Host stay the '
        'domain)');
    return n.copyWith(server: ip);
  }

  /// Resolves [host] to an IPv4: system DNS first (fast, works before the tunnel
  /// is up), then DoH as a fallback for a poisoned resolver. Null if neither
  /// answers.
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

  Future<List<ProxyNode>> _rankByPing(List<ProxyNode> nodes) async {
    // Bound the work: dedupe by server:port and only probe a sample.
    final Set<String> seen = <String>{};
    final List<ProxyNode> sample = <ProxyNode>[];
    for (final ProxyNode n in nodes) {
      if (seen.add('${n.server}:${n.port}')) sample.add(n);
      // A smaller sample keeps the first-connect probe short; the core's urltest
      // measures the full pool after connect, so this only needs to seed a good
      // initial pick, not rank everything.
      if (sample.length >= 16) break;
    }
    final Map<ProxyNode, int> ping = <ProxyNode, int>{};
    await Future.wait(sample.map((ProxyNode n) async {
      // Protocol-level probe (see node_probe.dart): a bare TCP connect ranks
      // DPI-blocked Cloudflare nodes as "fast", front-loading the urltest pool
      // with exits that can never carry traffic. `deep` is off here: this runs
      // before every connect, so it stops at the node's own handshake instead of
      // spending a round trip to the open internet per node. A 900ms per-probe
      // cap bounds the worst case (a blocked node that never answers) so the
      // overall rank stays inside its deadline.
      final NodeProbeResult r = await probeNode(n,
          timeout: const Duration(milliseconds: 900),
          deep: false,
          bypass: _active?.hardenTls ?? false);
      ping[n] = r.sortKey;
    }));
    final List<ProxyNode> ranked = <ProxyNode>[...sample]..sort(
        (ProxyNode a, ProxyNode b) =>
            (ping[a] ?? 1 << 30).compareTo(ping[b] ?? 1 << 30));
    // Append any nodes we didn't sample so the pool can still grow if needed.
    final Set<ProxyNode> inRanked = ranked.toSet();
    ranked.addAll(nodes.where((ProxyNode n) => !inRanked.contains(n)));
    return ranked;
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }
}

/// A minimal mutex for async sections (no package dependency).
class _AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() body) {
    final Future<T> result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
