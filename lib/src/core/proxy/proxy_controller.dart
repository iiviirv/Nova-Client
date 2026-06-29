import 'package:flutter/foundation.dart';

import '../models/proxy_profile.dart';
import 'singbox/singbox_config.dart';

/// High-level connection lifecycle states surfaced to the UI.
enum ProxyConnectionState { disconnected, connecting, connected, disconnecting, error }

extension ProxyConnectionStateX on ProxyConnectionState {
  bool get isBusy =>
      this == ProxyConnectionState.connecting || this == ProxyConnectionState.disconnecting;
  bool get isActive => this == ProxyConnectionState.connected;
}

/// A point-in-time traffic sample (bytes/second + cumulative bytes).
@immutable
class TrafficStats {
  const TrafficStats({
    this.uplinkBps = 0,
    this.downlinkBps = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
  });

  final double uplinkBps;
  final double downlinkBps;
  final int uplinkTotal;
  final int downlinkTotal;

  static const TrafficStats zero = TrafficStats();
}

/// The boundary between Nova Client's UI and the underlying proxy core.
///
/// Nova Client is an optimised Karing-style client: the actual data path is a
/// modified **sing-box** core, bound natively per platform (Android VpnService,
/// the Network Extension on iOS/macOS, a TUN service on desktop). That native
/// binding is intentionally **out of scope** for this milestone — see
/// [SingboxProxyController] for the platform-channel contract it implements.
///
/// Keeping the UI behind this abstraction means screens are built and reviewed
/// against [MockProxyController] today and switch to the real core by swapping
/// a single instance, with no UI changes.
abstract class ProxyController extends ChangeNotifier {
  ProxyConnectionState get state;
  TrafficStats get traffic;
  ProxyProfile? get activeProfile;

  /// Human-readable error from the last failed connection attempt, if any.
  String? get lastError;

  /// When the tunnel last became active, used by the dashboard's uptime timer.
  /// Maintained centrally by observing [state] on every notification so the
  /// per-platform implementations don't each have to track it.
  DateTime? _connectedSince;
  DateTime? get connectedSince => _connectedSince;

  @override
  void notifyListeners() {
    if (state.isActive) {
      _connectedSince ??= DateTime.now();
    } else {
      _connectedSince = null;
    }
    super.notifyListeners();
  }

  /// Supplies the current routing/DNS options at connect time. Set once at
  /// startup from the settings controller; the real (sing-box / desktop) hosts
  /// read it when building the config so the Routing and DNS screens actually
  /// take effect. Null falls back to the defaults.
  SingboxRouteOptions Function()? routeOptionsProvider;

  /// The options to build the next config with (defaults when unset).
  SingboxRouteOptions get routeOptions =>
      routeOptionsProvider?.call() ?? const SingboxRouteOptions();

  /// Selects the profile to connect with (does not connect).
  void selectProfile(ProxyProfile? profile);

  /// Starts the tunnel for [activeProfile].
  Future<void> connect();

  /// Tears the tunnel down.
  Future<void> disconnect();

  Future<void> toggle() {
    return state.isActive ? disconnect() : connect();
  }
}
