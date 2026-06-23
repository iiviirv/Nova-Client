import 'dart:async';

import 'package:flutter/services.dart';

import '../models/proxy_profile.dart';
import 'proxy_controller.dart';

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
///   * `{ "type": "traffic", "up": <bps>, "down": <bps>,
///        "upTotal": <bytes>, "downTotal": <bytes> }`
///   * `{ "type": "error", "message": "<text>" }`
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
    try {
      await _control.invokeMethod<void>('start', <String, dynamic>{
        'configJson': _buildSingboxConfig(profile),
      });
    } on PlatformException catch (e) {
      _lastError = e.message;
      _state = ProxyConnectionState.error;
      notifyListeners();
    }
  }

  @override
  Future<void> disconnect() async {
    _state = ProxyConnectionState.disconnecting;
    notifyListeners();
    try {
      await _control.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      _lastError = e.message;
      _state = ProxyConnectionState.error;
      notifyListeners();
    }
  }

  /// Translates a [ProxyProfile] into a sing-box config document. The full
  /// builder (outbound construction per protocol, DNS, routing rules, TUN
  /// inbound) is the next integration step; the profile URI is passed through
  /// so the native side can parse share links it already understands.
  String _buildSingboxConfig(ProxyProfile profile) {
    // Placeholder pass-through. Replaced by the structured config builder when
    // the native core is wired up.
    return profile.uri;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
