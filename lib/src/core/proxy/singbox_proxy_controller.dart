import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/proxy_profile.dart';
import 'proxy_controller.dart';
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
  })  : _control = control ?? const MethodChannel('nova.proxy/control'),
        _events = events ?? const EventChannel('nova.proxy/events') {
    _subscribe();
  }

  final MethodChannel _control;
  final EventChannel _events;
  StreamSubscription<dynamic>? _eventSub;

  /// If the tunnel never reports "connected" within this window the start has
  /// effectively hung (e.g. the core stuck initialising), so surface a real
  /// error instead of an endless "Connecting…".
  static const Duration _connectTimeout = Duration(seconds: 30);
  Timer? _watchdog;

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
      case 'state':
        _state = ProxyConnectionState.values.firstWhere(
          (s) => s.name == event['value'],
          orElse: () => _state,
        );
        // Any settled state clears the connect watchdog.
        if (_state != ProxyConnectionState.connecting) {
          _watchdog?.cancel();
          _watchdog = null;
        }
        notifyListeners();
      case 'traffic':
        _traffic = TrafficStats(
          uplinkBps: (event['up'] as num?)?.toDouble() ?? 0,
          downlinkBps: (event['down'] as num?)?.toDouble() ?? 0,
          uplinkTotal: (event['upTotal'] as num?)?.toInt() ?? 0,
          downlinkTotal: (event['downTotal'] as num?)?.toInt() ?? 0,
        );
        notifyListeners();
      case 'error':
        _lastError = event['message'] as String?;
        _state = ProxyConnectionState.error;
        notifyListeners();
    }
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
    _state = ProxyConnectionState.connecting;
    _lastError = null;
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
    List<ProxyNode> nodes = await resolveProfileNodes(profile);
    if (nodes.isEmpty) {
      throw FormatException(emptyResolveMessage(profile));
    }
    // Honour a manually pinned exit node: route through just that one instead of
    // letting the urltest auto-pick. Falls back to auto if it's no longer in the
    // subscription.
    final String? pin = profile.pinnedNode;
    if (pin != null) {
      for (final ProxyNode n in nodes) {
        if ('${n.server}:${n.port}' == pin) {
          nodes = <ProxyNode>[n];
          break;
        }
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
          final int ra = rank['${a.server}:${a.port}'] ?? 1 << 30;
          final int rb = rank['${b.server}:${b.port}'] ?? 1 << 30;
          return ra.compareTo(rb);
        });
    } else if (nodes.length > 1) {
      // First connect with no measured nodes yet: quickly ping-rank a sample so
      // Auto doesn't land on a dead/slow exit (which shows up as "connected but
      // no internet / no country"). Best-effort and time-boxed.
      nodes = await _rankByPing(nodes);
    }
    // iOS runs the core inside a Network Extension with a hard ~50 MB memory
    // cap, so build a lean config there (fewer nodes, normal MTU, no rule-sets)
    // to keep the extension from being OOM-killed mid-connection.
    final SingboxRouteOptions opts = routeOptions.copyWith(lean: Platform.isIOS);
    return nodes.length == 1
        ? SingboxConfig.build(nodes.first, options: opts)
        : SingboxConfig.buildMulti(nodes, options: opts);
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
      final Stopwatch sw = Stopwatch()..start();
      try {
        final Socket s = await Socket.connect(n.server, n.port,
            timeout: const Duration(milliseconds: 1500));
        sw.stop();
        s.destroy();
        ping[n] = sw.elapsedMilliseconds;
      } catch (_) {
        ping[n] = 1 << 30; // unreachable -> sort last
      }
    }));
    final List<ProxyNode> ranked = <ProxyNode>[...sample]
      ..sort((ProxyNode a, ProxyNode b) =>
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
