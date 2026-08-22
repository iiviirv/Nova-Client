import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/proxy/proxy_controller.dart';
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

/// The uTLS ClientHello fingerprints a user can force. Empty string = Auto (let
/// the per-carrier ISP profile pick). These are the sing-box utls names that
/// matter for Iran DPI; 'randomized' rotates a fresh fingerprint each handshake.
const List<String> kFingerprintChoices = <String>[
  '', // Auto
  'chrome',
  'firefox',
  'safari',
  'ios',
  'edge',
  'randomized',
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
  static const String _kAutoSysProxy = 'nova.desktop.autoSystemProxy';
  static const String _kUrlTestUrl = 'nova.urltest.url';
  static const String _kUrlTestTimeout = 'nova.urltest.timeout';
  static const String _kUrlTestInterval = 'nova.urltest.interval';
  static const String _kUrlTestTolerance = 'nova.urltest.tolerance';
  static const String _kHy2Down = 'nova.hy2.downMbps';
  static const String _kHy2Up = 'nova.hy2.upMbps';
  static const String _kAutoIsp = 'nova.isp.autoOptimize';
  static const String _kFingerprint = 'nova.tls.fingerprint';
  static const String _kVerboseLog = 'nova.log.verboseCore';
  static const String _kPanelUrl = 'nova.panel.url';
  static const String _kPanelShortcut = 'nova.panel.shortcut';
  static const String _kProxyPort = 'nova.proxy.port';
  static const String _kMobileProxyMode = 'nova.proxy.mobileMode';
  static const String _kIosAutoReconnect = 'nova.ios.autoReconnect';

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

  /// Desktop proxy mode: set the OS system proxy to Nova's local port on
  /// connect. Off means the user points apps at the port themselves.
  bool _autoSystemProxy = true;
  bool get autoSystemProxy => _autoSystemProxy;

  /// URL-test settings (see SingboxRouteOptions): test address, per-node
  /// timeout, live re-test interval, switch tolerance.
  String _urlTestUrl = kDefaultUrlTestUrl;
  int _urlTestTimeoutSec = kDefaultUrlTestTimeoutSec;
  int _urlTestIntervalSec = kDefaultUrlTestIntervalSec;
  int _urlTestToleranceMs = kDefaultUrlTestToleranceMs;
  String get urlTestUrl => _urlTestUrl;
  int get urlTestTimeoutSec => _urlTestTimeoutSec;
  int get urlTestIntervalSec => _urlTestIntervalSec;
  int get urlTestToleranceMs => _urlTestToleranceMs;

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

  /// Auto-optimize per carrier: detect the phone's ISP (SIM MCC-MNC) and apply
  /// the DPI-optimal uTLS fingerprint + fragmentation from the Nova server's
  /// `/isp-profile` before connecting. Mobile only (desktop has no SIM). On by
  /// default; the user can turn it off to keep each node's own fingerprint.
  bool _autoOptimizeCarrier = true;
  bool get autoOptimizeCarrier => _autoOptimizeCarrier;

  /// A user-forced uTLS fingerprint (empty = Auto). When set it WINS over the
  /// per-carrier profile and each node's own value, so a user can experiment or
  /// lock in what the tuner found best for their network.
  String _fingerprint = '';
  String get fingerprint => _fingerprint;

  /// Run the core at `info` instead of `warn`, so the Logs screen shows what it
  /// is doing rather than only what it is complaining about. Off by default:
  /// `info` logs every routed connection, which is real work on a phone for a
  /// screen that is usually closed. Takes effect on the next connect.
  bool _verboseCoreLog = false;
  bool get verboseCoreLog => _verboseCoreLog;

  /// The user's own Nova Server admin panel URL, entered in Settings. A panel
  /// lives behind a secret admin path that cannot be derived from a
  /// subscription URL, so guessing the subscription host's root (what the app
  /// used to do) opened a 404. Empty means not configured.
  String _panelUrl = '';
  String get panelUrl => _panelUrl;

  /// Show a "Panel" entry on the dashboard's top switcher next to Summary and
  /// Configs, so the panel is one tap away. Only meaningful with [panelUrl].
  bool _panelShortcut = false;
  bool get panelShortcut => _panelShortcut;

  /// The local SOCKS/HTTP port proxy mode listens on. Movable because 2080 is
  /// the default every client in this space uses, so anyone already running one
  /// of those has the port taken.
  int _proxyPort = kDefaultLocalProxyPort;
  int get proxyPort => _proxyPort;

  /// Android and iOS: run as a local SOCKS5/HTTP proxy instead of a full-device
  /// tunnel. The phone's own traffic is untouched and only an app pointed at
  /// [proxyPort] goes through Nova, which is also the only way to have Nova and
  /// another VPN up at the same time. Off by default: a VPN that only some apps
  /// use is the exception, not the expectation.
  bool _mobileProxyMode = false;
  bool get mobileProxyMode => _mobileProxyMode;

  /// iOS only: let the system bring the tunnel back by itself (an on-demand
  /// rule), so a Network Extension that iOS kills under memory pressure does not
  /// leave the user quietly offline.
  ///
  /// Off by default, because the same rule is what stops the VPN switch in the
  /// iPhone's own Settings from working: turning Nova off there brought it
  /// straight back, and turning on a different VPN fought with it. The OS
  /// switch has to win unless the user has explicitly asked otherwise.
  bool _iosAutoReconnect = false;
  bool get iosAutoReconnect => _iosAutoReconnect;

  /// A usable https/http origin+path from [panelUrl], or null if it is empty
  /// or not a URL we can open.
  Uri? get panelUri {
    final String raw = _panelUrl.trim();
    if (raw.isEmpty) return null;
    final Uri? u = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (u == null || u.host.isEmpty) return null;
    if (u.scheme != 'https' && u.scheme != 'http') return null;
    return u;
  }

  /// The options the proxy controllers build the next config with.
  SingboxRouteOptions get routeOptions => SingboxRouteOptions(
        mode: _mode,
        blockAds: _blockAds,
        bypassIran: _bypassIran,
        bypassLan: _bypassLan,
        dns: _dns,
        hy2UpMbps: _hy2UpMbps,
        hy2DownMbps: _hy2DownMbps,
        autoOptimizeCarrier: _autoOptimizeCarrier &&
            (Platform.isAndroid || Platform.isIOS),
        // A manual choice pre-fills the override; the ISP resolver leaves it
        // alone (see SingboxProxyController), so manual always wins.
        fingerprintOverride: _fingerprint.isEmpty ? null : _fingerprint,
        verboseCoreLog: _verboseCoreLog,
        urlTestUrl: _urlTestUrl,
        urlTestTimeoutSec: _urlTestTimeoutSec,
        urlTestIntervalSec: _urlTestIntervalSec,
        urlTestToleranceMs: _urlTestToleranceMs,
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
    _autoSystemProxy = p.getBool(_kAutoSysProxy) ?? true;
    _proxyPort = p.getInt(_kProxyPort) ?? kDefaultLocalProxyPort;
    _mobileProxyMode = p.getBool(_kMobileProxyMode) ?? false;
    _iosAutoReconnect = p.getBool(_kIosAutoReconnect) ?? false;
    _urlTestUrl = p.getString(_kUrlTestUrl) ?? kDefaultUrlTestUrl;
    _urlTestTimeoutSec = p.getInt(_kUrlTestTimeout) ?? kDefaultUrlTestTimeoutSec;
    _urlTestIntervalSec = p.getInt(_kUrlTestInterval) ?? kDefaultUrlTestIntervalSec;
    _urlTestToleranceMs = p.getInt(_kUrlTestTolerance) ?? kDefaultUrlTestToleranceMs;
    _hy2DownMbps = p.getInt(_kHy2Down) ?? 0;
    _hy2UpMbps = p.getInt(_kHy2Up) ?? 0;
    _autoOptimizeCarrier = p.getBool(_kAutoIsp) ?? true;
    _fingerprint = p.getString(_kFingerprint) ?? '';
    _verboseCoreLog = p.getBool(_kVerboseLog) ?? false;
    _panelUrl = p.getString(_kPanelUrl) ?? '';
    _panelShortcut = p.getBool(_kPanelShortcut) ?? false;
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

  Future<void> setAutoOptimizeCarrier(bool v) async {
    if (v == _autoOptimizeCarrier) return;
    _autoOptimizeCarrier = v;
    notifyListeners();
    await _prefs?.setBool(_kAutoIsp, v);
  }

  /// Force a uTLS fingerprint (empty = Auto). Persisted so it survives restarts;
  /// the tuner calls this to lock in the winner.
  Future<void> setFingerprint(String fp) async {
    if (fp == _fingerprint) return;
    _fingerprint = fp;
    notifyListeners();
    await _prefs?.setString(_kFingerprint, fp);
  }

  /// Turn detailed core logging on or off. Applies to the next connection: the
  /// level is baked into the config handed to the core when the tunnel starts.
  Future<void> setVerboseCoreLog(bool v) async {
    if (v == _verboseCoreLog) return;
    _verboseCoreLog = v;
    notifyListeners();
    await _prefs?.setBool(_kVerboseLog, v);
  }

  Future<void> setPanelUrl(String v) async {
    final String t = v.trim();
    if (t == _panelUrl) return;
    _panelUrl = t;
    notifyListeners();
    await _prefs?.setString(_kPanelUrl, t);
  }

  Future<void> setProxyPort(int v) async {
    final int c = v.clamp(1, 65535);
    if (c == _proxyPort) return;
    _proxyPort = c;
    notifyListeners();
    await _prefs?.setInt(_kProxyPort, c);
  }

  Future<void> setMobileProxyMode(bool v) async {
    if (v == _mobileProxyMode) return;
    _mobileProxyMode = v;
    notifyListeners();
    await _prefs?.setBool(_kMobileProxyMode, v);
  }

  Future<void> setIosAutoReconnect(bool v) async {
    if (v == _iosAutoReconnect) return;
    _iosAutoReconnect = v;
    notifyListeners();
    await _prefs?.setBool(_kIosAutoReconnect, v);
  }

  Future<void> setPanelShortcut(bool v) async {
    if (v == _panelShortcut) return;
    _panelShortcut = v;
    notifyListeners();
    await _prefs?.setBool(_kPanelShortcut, v);
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

  Future<void> setUrlTestUrl(String v) async {
    final String t = v.trim();
    if (t == _urlTestUrl) return;
    _urlTestUrl = t;
    notifyListeners();
    await _prefs?.setString(_kUrlTestUrl, t);
  }

  Future<void> setUrlTestTimeoutSec(int v) async {
    final int c = v.clamp(1, 60);
    if (c == _urlTestTimeoutSec) return;
    _urlTestTimeoutSec = c;
    notifyListeners();
    await _prefs?.setInt(_kUrlTestTimeout, c);
  }

  Future<void> setUrlTestIntervalSec(int v) async {
    final int c = v.clamp(10, 86400);
    if (c == _urlTestIntervalSec) return;
    _urlTestIntervalSec = c;
    notifyListeners();
    await _prefs?.setInt(_kUrlTestInterval, c);
  }

  Future<void> setUrlTestToleranceMs(int v) async {
    final int c = v.clamp(0, 5000);
    if (c == _urlTestToleranceMs) return;
    _urlTestToleranceMs = c;
    notifyListeners();
    await _prefs?.setInt(_kUrlTestTolerance, c);
  }

  Future<void> setAutoSystemProxy(bool v) async {
    if (v == _autoSystemProxy) return;
    _autoSystemProxy = v;
    notifyListeners();
    await _prefs?.setBool(_kAutoSysProxy, v);
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
