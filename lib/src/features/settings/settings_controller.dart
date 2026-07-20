import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/proxy/singbox/singbox_config.dart';

/// A named DNS resolver choice, mirroring the native Android DNS picker.
class NovaDnsChoice {
  const NovaDnsChoice(this.label, this.server);

  /// What the user sees.
  final String label;

  /// The upstream IP the DoH server resolves through. Empty = Nova default.
  final String server;
}

/// The DNS resolvers Nova offers. IP-based so they need no bootstrap.
const List<NovaDnsChoice> kNovaDnsChoices = <NovaDnsChoice>[
  NovaDnsChoice('Default', ''),
  NovaDnsChoice('Cloudflare', '1.1.1.1'),
  NovaDnsChoice('Google', '8.8.8.8'),
  NovaDnsChoice('Quad9', '9.9.9.9'),
  NovaDnsChoice('AdGuard', '94.140.14.14'),
];

/// Holds the connection-affecting options the user controls (routing mode, the
/// rule toggles, and the DNS resolver) and persists them. The proxy controllers
/// read [routeOptions] when they build the next sing-box config, so these are
/// the real knobs behind the Routing and DNS screens (previously the Routing
/// screen was cosmetic and applied nothing).
class SettingsController extends ChangeNotifier {
  SettingsController({SharedPreferences? prefs}) : _prefs = prefs {
    _load();
  }

  static const String _kMode = 'nova.route.mode';
  static const String _kBlockAds = 'nova.route.blockAds';
  static const String _kBypassIran = 'nova.route.bypassIran';
  static const String _kBypassLan = 'nova.route.bypassLan';
  static const String _kDns = 'nova.dns';
  static const String _kTunMode = 'nova.desktop.tun';
  static const String _kHy2Down = 'nova.hy2.downMbps';
  static const String _kHy2Up = 'nova.hy2.upMbps';

  SharedPreferences? _prefs;

  SingboxMode _mode = SingboxMode.rule;
  SingboxMode get mode => _mode;

  bool _blockAds = true;
  bool get blockAds => _blockAds;

  bool _bypassIran = true;
  bool get bypassIran => _bypassIran;

  bool _bypassLan = true;
  bool get bypassLan => _bypassLan;

  String _dns = '';
  String get dns => _dns;

  /// Desktop only: route the whole machine through a TUN device (needs one
  /// admin/UAC approval) instead of just setting the OS proxy. Defaults ON for
  /// desktop so every app on the device is proxied (full-device VPN), matching
  /// what mobile already does; the user can turn it off in Routing to fall back
  /// to the unprivileged OS-proxy path. Mobile ignores this (it is always TUN).
  bool _tunMode = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool get tunMode => _tunMode;

  /// Hysteria2 "speed boost": the user's line speed in Mbps. When >0 it turns on
  /// the Brutal congestion controller for Hysteria2 nodes (fixed-rate, ignores
  /// loss), which pushes through loss-based throttling that BBR can't. 0 = off =
  /// BBR (the safe default). Set to the REAL line speed: too high floods, too
  /// low caps.
  int _hy2DownMbps = 0;
  int get hy2DownMbps => _hy2DownMbps;

  int _hy2UpMbps = 0;
  int get hy2UpMbps => _hy2UpMbps;

  bool get hy2BoostOn => _hy2DownMbps > 0 || _hy2UpMbps > 0;

  /// The options the proxy controllers build the next config with.
  SingboxRouteOptions get routeOptions => SingboxRouteOptions(
        mode: _mode,
        blockAds: _blockAds,
        bypassIran: _bypassIran,
        bypassLan: _bypassLan,
        dns: _dns,
        hy2UpMbps: _hy2UpMbps,
        hy2DownMbps: _hy2DownMbps,
      );

  void _load() {
    final SharedPreferences? p = _prefs;
    if (p == null) return;
    final String? m = p.getString(_kMode);
    if (m != null) {
      _mode = SingboxMode.values.firstWhere(
        (SingboxMode e) => e.name == m,
        orElse: () => SingboxMode.rule,
      );
    }
    _blockAds = p.getBool(_kBlockAds) ?? true;
    _bypassIran = p.getBool(_kBypassIran) ?? true;
    _bypassLan = p.getBool(_kBypassLan) ?? true;
    _dns = p.getString(_kDns) ?? '';
    _tunMode = p.getBool(_kTunMode) ??
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
    _hy2DownMbps = p.getInt(_kHy2Down) ?? 0;
    _hy2UpMbps = p.getInt(_kHy2Up) ?? 0;
  }

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    _load();
    notifyListeners();
  }

  Future<void> setMode(SingboxMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _prefs?.setString(_kMode, mode.name);
  }

  Future<void> setBlockAds(bool v) async {
    if (v == _blockAds) return;
    _blockAds = v;
    notifyListeners();
    await _prefs?.setBool(_kBlockAds, v);
  }

  Future<void> setBypassIran(bool v) async {
    if (v == _bypassIran) return;
    _bypassIran = v;
    notifyListeners();
    await _prefs?.setBool(_kBypassIran, v);
  }

  Future<void> setBypassLan(bool v) async {
    if (v == _bypassLan) return;
    _bypassLan = v;
    notifyListeners();
    await _prefs?.setBool(_kBypassLan, v);
  }

  Future<void> setDns(String server) async {
    if (server == _dns) return;
    _dns = server;
    notifyListeners();
    await _prefs?.setString(_kDns, server);
  }

  Future<void> setTunMode(bool v) async {
    if (v == _tunMode) return;
    _tunMode = v;
    notifyListeners();
    await _prefs?.setBool(_kTunMode, v);
  }

  /// Set the Hysteria2 line-speed hints (Mbps). Pass 0/0 to turn the boost off
  /// (back to BBR). Clamped to a sane range so a fat-fingered value can't ask
  /// Brutal to flood at absurd rates.
  Future<void> setHy2Bandwidth({required int downMbps, required int upMbps}) async {
    final int down = downMbps.clamp(0, 1000);
    final int up = upMbps.clamp(0, 1000);
    if (down == _hy2DownMbps && up == _hy2UpMbps) return;
    _hy2DownMbps = down;
    _hy2UpMbps = up;
    notifyListeners();
    await _prefs?.setInt(_kHy2Down, down);
    await _prefs?.setInt(_kHy2Up, up);
  }
}
