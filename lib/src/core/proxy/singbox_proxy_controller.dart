import 'dart:async';
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
import 'singbox/proxy_node.dart';
import 'singbox/singbox_config.dart';
import 'subscription.dart';

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
            final NovaLogLevel level =
                novaLogLevelFromCore((line['level'] as num?)?.toInt() ?? 4);
            // Quiet means what `log.level: warn` was supposed to mean: the core's
            // complaints, not a line per routed connection.
            if (!verbose && level.index < NovaLogLevel.warn.index) continue;
            NovaLog.instance.writeCore('${line['message']}', level: level);
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
    final CoreNodeHealth next = parseCoreGroups(_coreTagKeys, raw);
    final CoreNodeHealth cur = coreHealth.value;
    if (next.selectedKey == cur.selectedKey &&
        mapEquals(next.delayMsByKey, cur.delayMsByKey)) {
      return;
    }
    coreHealth.value = next;
  }

  /// Turns the host's `groups` payload into a [CoreNodeHealth], mapping the
  /// config's `node-i` outbound tags back to real node keys with [tagKeys].
  ///
  /// Exposed for tests because this is the fiddly part: it drops 0-delay items
  /// (the core's "no successful test yet"), keeps only the auto-select group
  /// `proxy`, and ignores tags it has no mapping for.
  @visibleForTesting
  static CoreNodeHealth parseCoreGroups(
      Map<String, String> tagKeys, Object? raw) {
    if (raw is! List) return CoreNodeHealth.empty;
    final Map<String, int> delays = <String, int>{};
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
          // A 0 delay from the core is "no successful test yet", which is not a
          // latency we can honestly show, so it stays absent (the row keeps its
          // "tested when you connect" note) rather than reading as 0 ms.
          if (key != null && delay > 0) delays[key] = delay;
        }
      }
    }
    return CoreNodeHealth(delayMsByKey: delays, selectedKey: selectedKey);
  }

  @override
  void selectProfile(ProxyProfile? profile) {
    _active = profile;
    notifyListeners();
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

    // An AmneziaWG config handed to a core built without it produces a tunnel
    // that comes up and carries nothing, which reads as a broken server. Ask
    // the core first and say what is actually wrong. An unmeasurable host
    // leaves the verdict unknown and the connect proceeds unchanged.
    if (CoreFeatures.usesAwg(config)) {
      await _features.load();
      if (_features.awgUnsupported) {
        _lastError = _features.awgUnsupportedMessage;
        _state = ProxyConnectionState.error;
        notifyListeners();
        return;
      }
    }

    try {
      await _control.invokeMethod<void>('start', <String, dynamic>{
        'configJson': config,
        // Bundled rule-set files the lean iOS config references as local
        // rule-sets. The host writes them next to the config in the App Group.
        if (Platform.isIOS) 'ruleSets': await _leanRuleSets(),
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
    // A real user disconnect clears the heal guard so the next session can heal
    // again; the heal's own reconnect (which disconnects first) must not.
    if (!_healing) _autoHealTried = false;
    exitUnreachable = false;
    _state = ProxyConnectionState.disconnecting;
    notifyListeners();
    try {
      await _control.invokeMethod<void>('stop');
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
    // Honour a manually pinned exit node: route through just that one instead of
    // letting the urltest auto-pick. Falls back to auto if it's no longer in the
    // subscription.
    final String? pin = profile.pinnedNode;
    if (pin != null) {
      bool honoured = false;
      for (final ProxyNode n in nodes) {
        if (proxyNodeMatchesKey(n, pin)) {
          // An xhttp node cannot be built at all (sing-box has no such
          // transport), and the pin self-heal only runs after a successful
          // connect, so honouring the pin here would leave the profile
          // permanently unconnectable with no way back. Treat it like a pin that
          // is no longer in the subscription and fall through to auto.
          if (n.network == 'xhttp') break;
          nodes = <ProxyNode>[n];
          honoured = true;
          NovaLog.instance.write(
              'Using your chosen server ${n.server}:${n.port} '
              '(${n.protocol.label})');
          break;
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
      // no internet / no country"). Best-effort and time-boxed.
      nodes = await _rankByPing(nodes);
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
      // by the user, applied only to clean-IP fronted nodes.
      hardenTls: profile.hardenTls,
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
    // Remember which real node each `node-i` tag maps to, so the core's per-node
    // urltest results (which come back keyed by those tags) can be shown against
    // the right server in the list. Only a real multi-node pool has a urltest
    // group; a single/pinned node has none.
    if (nodes.length == 1) {
      _coreTagKeys = const <String, String>{};
    } else {
      final List<String> keys =
          SingboxConfig.orderedMultiNodeKeys(nodes, options: tuned);
      _coreTagKeys = <String, String>{
        for (int i = 0; i < keys.length; i++) 'node-$i': keys[i],
      };
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
  Future<List<ProxyNode>> _rankByPing(List<ProxyNode> nodes) async {
    // Bound the work: dedupe by server:port and only probe a sample.
    final Set<String> seen = <String>{};
    final List<ProxyNode> sample = <ProxyNode>[];
    for (final ProxyNode n in nodes) {
      if (seen.add('${n.server}:${n.port}')) sample.add(n);
      if (sample.length >= 30) break;
    }
    final Map<ProxyNode, int> ping = <ProxyNode, int>{};
    await Future.wait(sample.map((ProxyNode n) async {
      // Protocol-level probe (see node_probe.dart): a bare TCP connect ranks
      // DPI-blocked Cloudflare nodes as "fast", front-loading the urltest pool
      // with exits that can never carry traffic. `deep` is off here: this runs
      // before every connect, so it stops at the node's own handshake instead of
      // spending a round trip to the open internet per node.
      final NodeProbeResult r = await probeNode(n,
          timeout: const Duration(milliseconds: 1500),
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
