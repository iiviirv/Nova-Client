import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../vps/insecure_http.dart';
import 'fronted_http.dart';
import 'relay_client.dart';
import 'relay_link.dart';

/// Holds the Google relay configuration and hands out a [RelayClient] when it is
/// enabled. The relay lets the app fetch its subscription and reach the /admin
/// API through Google when the panel's own domain is blocked. Persisted in the
/// platform secure store (the exec URL is effectively a secret).
class RelayController extends ChangeNotifier {
  RelayController();

  static const String _key = 'google_relay';
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  bool _enabled = false;
  String _execUrl = '';
  String _authKey = '';
  bool _allowInsecure = false;
  bool _frontEnabled = false;
  String _frontSni = kDefaultFrontSni;
  String _frontIp = '';

  bool get enabled => _enabled;
  String get execUrl => _execUrl;
  String get authKey => _authKey;

  /// A self-hosted relay node may serve a self-signed cert. Google Apps Script
  /// always has a valid cert, so leave this off for the Google relay.
  bool get allowInsecure => _allowInsecure;

  /// Domain-front the connection to the relay endpoint: dial a CDN edge IP with
  /// SNI [frontSni] but keep the exec URL's real Host, so a DPI box that blocks
  /// the relay host's SNI (for example `script.google.com`) still can't see or
  /// stop it. Only meaningful when the exec URL is a frontable CDN host (Apps
  /// Script / Google); a bare VPS `/relay` can't be fronted, so leave it off
  /// there. Mutually exclusive with [allowInsecure] (fronting validates the
  /// front cert).
  bool get frontEnabled => _frontEnabled;
  String get frontSni => _frontSni.trim().isEmpty ? kDefaultFrontSni : _frontSni;

  /// The chosen front edge IP, or the first of the built-in Google pool when
  /// unset. [pickBestFrontIp] refreshes this to a verified-live edge.
  String get frontIp => _frontIp.trim().isEmpty ? kGoogleFrontIps.first : _frontIp;

  /// Configured (has an exec URL) and turned on.
  bool get active => _enabled && _execUrl.trim().isNotEmpty;

  Future<void> load() async {
    try {
      final String? raw = await _secure.read(key: _key);
      if (raw == null || raw.isEmpty) return;
      final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
      _enabled = j['enabled'] == true;
      _execUrl = (j['execUrl'] as String?) ?? '';
      _authKey = (j['authKey'] as String?) ?? '';
      _allowInsecure = j['allowInsecure'] == true;
      _frontEnabled = j['frontEnabled'] == true;
      _frontSni = (j['frontSni'] as String?) ?? kDefaultFrontSni;
      _frontIp = (j['frontIp'] as String?) ?? '';
      notifyListeners();
    } catch (_) {/* ignore a corrupt blob */}
  }

  Future<void> save({
    bool? enabled,
    String? execUrl,
    String? authKey,
    bool? allowInsecure,
    bool? frontEnabled,
    String? frontSni,
    String? frontIp,
  }) async {
    if (enabled != null) _enabled = enabled;
    if (execUrl != null) _execUrl = execUrl.trim();
    if (authKey != null) _authKey = authKey.trim();
    if (allowInsecure != null) _allowInsecure = allowInsecure;
    if (frontEnabled != null) _frontEnabled = frontEnabled;
    if (frontSni != null) _frontSni = frontSni.trim();
    if (frontIp != null) _frontIp = frontIp.trim();
    await _secure.write(
      key: _key,
      value: jsonEncode(<String, dynamic>{
        'enabled': _enabled,
        'execUrl': _execUrl,
        'authKey': _authKey,
        'allowInsecure': _allowInsecure,
        'frontEnabled': _frontEnabled,
        'frontSni': _frontSni,
        'frontIp': _frontIp,
      }),
    );
    notifyListeners();
  }

  Future<void> clear() async {
    _enabled = false;
    _execUrl = '';
    _authKey = '';
    _allowInsecure = false;
    _frontEnabled = false;
    _frontSni = kDefaultFrontSni;
    _frontIp = '';
    await _secure.delete(key: _key);
    notifyListeners();
  }

  /// The inner transport for a [RelayClient]: a fronted client when domain
  /// fronting is on, an insecure client for a self-signed node, else the plain
  /// default. Fronting takes precedence (it validates a real CDN cert).
  http.Client? _innerFor(bool front, bool insecure, String sni, String ip) {
    if (front) return buildFrontedClient(frontSni: sni, edgeIp: ip);
    if (insecure) return buildInsecureClient();
    return null;
  }

  /// The transport the relay would use right now (fronted / insecure / plain),
  /// so the full tunnel can ride the same path without duplicating the config.
  /// Null means "use the default validating client".
  http.Client? buildTransport() =>
      _innerFor(_frontEnabled, _allowInsecure, frontSni, frontIp);

  /// Endpoint-aware transport for the full tunnel. Fronting only reaches
  /// Google-frontable hosts (an Apps Script `/exec` that forwards to the node),
  /// so a direct VPS `/tunnel` must NOT be fronted. For a direct endpoint we
  /// fall back to the insecure client when the user allowed a self-signed
  /// certificate, else the default validating client.
  http.Client? transportFor(String endpoint) {
    final String host = Uri.tryParse(endpoint)?.host ?? '';
    final bool frontable = host.endsWith('google.com') ||
        host.endsWith('googleusercontent.com');
    if (_frontEnabled && frontable) {
      return buildFrontedClient(frontSni: frontSni, edgeIp: frontIp);
    }
    if (_allowInsecure) return buildInsecureClient();
    return null;
  }

  RelayClient _build(
    String url,
    String key,
    bool insecure,
    bool front,
    String sni,
    String ip,
  ) =>
      RelayClient(
        execUrl: url,
        authKey: key.isEmpty ? null : key,
        inner: _innerFor(front, insecure, sni, ip),
      );

  /// A [RelayClient] when the relay is active, else null. Callers use it as
  /// `relay.clientOrNull() ?? theirNormalClient`.
  RelayClient? clientOrNull() {
    if (!active) return null;
    return _build(
        _execUrl, _authKey, _allowInsecure, _frontEnabled, frontSni, frontIp);
  }

  /// Apply an imported [RelayLinkData] to the relay config and turn it on, so a
  /// scanned/pasted setup works with no hand-typing.
  Future<void> applyLink(RelayLinkData d) async {
    await save(
      enabled: true,
      execUrl: d.execUrl,
      authKey: d.authKey,
      allowInsecure: d.allowInsecure,
      frontEnabled: d.frontEnabled,
      frontSni: d.frontSni.isEmpty ? _frontSni : d.frontSni,
      frontIp: d.frontIp,
    );
  }

  /// The current relay config as [RelayLinkData], for exporting a share link.
  /// Tunnel fields are threaded in by the caller (they live on TunnelController).
  RelayLinkData toLinkData({
    String tunnelUrl = '',
    String tunnelKey = '',
    int? tunnelPort,
    String name = '',
  }) =>
      RelayLinkData(
        execUrl: _execUrl,
        authKey: _authKey,
        allowInsecure: _allowInsecure,
        frontEnabled: _frontEnabled,
        frontSni: _frontSni,
        frontIp: _frontIp,
        tunnelUrl: tunnelUrl,
        tunnelKey: tunnelKey,
        tunnelPort: tunnelPort,
        name: name,
      );

  /// Probe the built-in Google front pool and persist the first live edge IP as
  /// [frontIp]. Returns the chosen IP, or null if none answered. Called from the
  /// setup screen so the user gets a working front without hand-picking an IP.
  Future<String?> pickBestFrontIp() async {
    final String? ip = await pickFrontIp(frontSni: frontSni);
    if (ip != null) {
      _frontIp = ip;
      notifyListeners();
    }
    return ip;
  }

  /// Wrap [target] to go through the relay when active; otherwise return it.
  http.Client wrap(http.Client target) => clientOrNull() ?? target;

  /// A subscription fetcher (Uri to body) that goes through the relay, or null
  /// when the relay is off. Shaped to match the resolver's SubscriptionFetcher.
  Future<String> Function(Uri)? subFetcher() {
    final RelayClient? c = clientOrNull();
    if (c == null) return null;
    return (Uri url) async {
      try {
        final http.Response r = await c.get(url).timeout(const Duration(seconds: 30));
        return r.body;
      } finally {
        c.close();
      }
    };
  }

  /// Prove the relay works by fetching a tiny public endpoint through it.
  /// Uses the given values if provided (so the setup screen can test before
  /// saving), else the stored config. When [frontEnabled] is on, the relay
  /// endpoint itself is reached over the fronted edge, so a passing test also
  /// proves the front path.
  Future<void> test({
    String? execUrl,
    String? authKey,
    bool? allowInsecure,
    bool? frontEnabled,
    String? frontSni,
    String? frontIp,
  }) async {
    final String url = (execUrl ?? _execUrl).trim();
    if (url.isEmpty) throw RelayException('paste the relay URL first');
    final RelayClient c = _build(
      url,
      (authKey ?? _authKey).trim(),
      allowInsecure ?? _allowInsecure,
      frontEnabled ?? _frontEnabled,
      (frontSni ?? this.frontSni),
      (frontIp ?? this.frontIp),
    );
    try {
      final http.Response r = await c
          .get(Uri.parse('https://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 400) {
        throw RelayException('the relay reached Google but got HTTP ${r.statusCode}');
      }
    } finally {
      c.close();
    }
  }

  /// Prove domain fronting works on its own, WITHOUT the relay: dial the front
  /// edge, hand-shake as [frontSni], and fetch a Google-owned probe by Host. A
  /// 2xx/3xx means the edge routes by Host on this network, so the fronted relay
  /// path will work too. Throws [RelayException] on any failure.
  Future<void> testDirect({String? frontSni, String? frontIp}) async {
    final String sni = (frontSni ?? this.frontSni).trim().isEmpty
        ? kDefaultFrontSni
        : (frontSni ?? this.frontSni).trim();
    final String ip = (frontIp ?? this.frontIp).trim().isEmpty
        ? kGoogleFrontIps.first
        : (frontIp ?? this.frontIp).trim();
    try {
      final int code = await frontProbe(frontSni: sni, edgeIp: ip);
      if (code >= 400) {
        throw RelayException('the front edge answered HTTP $code');
      }
    } on RelayException {
      rethrow;
    } catch (e) {
      throw RelayException('front edge unreachable: $e');
    }
  }
}
