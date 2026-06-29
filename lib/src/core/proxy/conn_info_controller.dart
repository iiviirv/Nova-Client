import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'proxy_controller.dart';

/// Live connection info shown on the dashboard metrics block: the public exit
/// IP, the country it geolocates to, and a round-trip ping. Mirrors the native
/// Android `NovaConnInfo`, which polls roughly every 6 seconds while connected.
@immutable
class ConnInfo {
  const ConnInfo({this.ip, this.countryCode, this.countryName, this.pingMs});

  final String? ip;
  final String? countryCode; // ISO-2, e.g. "DE"
  final String? countryName;
  final int? pingMs;

  bool get hasGeo => (countryCode?.isNotEmpty ?? false);

  static const ConnInfo empty = ConnInfo();
}

/// Polls the exit IP/country/ping while the proxy is connected and clears it
/// when disconnected. Best-effort: any network failure leaves the last good
/// value (or empty) and never throws into the UI.
class ConnInfoController extends ChangeNotifier {
  ConnInfoController(this._proxy) {
    _proxy.addListener(_onProxyChanged);
  }

  final ProxyController _proxy;

  ConnInfo _info = ConnInfo.empty;
  ConnInfo get info => _info;

  bool _loading = false;
  bool get loading => _loading;

  Timer? _timer;
  bool _wasActive = false;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);

  void _onProxyChanged() {
    final bool active = _proxy.state.isActive;
    if (active && !_wasActive) {
      _start();
    } else if (!active && _wasActive) {
      _stop();
    }
    _wasActive = active;
  }

  void _start() {
    _info = ConnInfo.empty;
    _loading = true;
    notifyListeners();
    _refresh();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _loading = false;
    _info = ConnInfo.empty;
    notifyListeners();
  }

  Future<void> _refresh() async {
    final int? ping = await _measurePing();
    final ConnInfo? geo = await _fetchGeo();
    _loading = false;
    _info = ConnInfo(
      ip: geo?.ip ?? _info.ip,
      countryCode: geo?.countryCode ?? _info.countryCode,
      countryName: geo?.countryName ?? _info.countryName,
      pingMs: ping ?? _info.pingMs,
    );
    notifyListeners();
  }

  /// ip-api.com over plain HTTP (the native app whitelists cleartext for it);
  /// returns IP + ISO country code/name.
  Future<ConnInfo?> _fetchGeo() async {
    try {
      final Uri url = Uri.parse(
        'http://ip-api.com/json/?fields=status,country,countryCode,query',
      );
      final HttpClientRequest req = await _client.getUrl(url);
      final HttpClientResponse res = await req.close();
      if (res.statusCode != 200) return null;
      final String body = await res.transform(utf8.decoder).join();
      final Map<String, dynamic> j = jsonDecode(body) as Map<String, dynamic>;
      if (j['status'] != 'success') return null;
      return ConnInfo(
        ip: j['query'] as String?,
        countryCode: (j['countryCode'] as String?)?.toUpperCase(),
        countryName: j['country'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Round-trip time to Cloudflare's trace endpoint as a coarse ping.
  Future<int?> _measurePing() async {
    try {
      final Stopwatch sw = Stopwatch()..start();
      final HttpClientRequest req = await _client
          .getUrl(Uri.parse('https://1.1.1.1/cdn-cgi/trace'));
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _proxy.removeListener(_onProxyChanged);
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }
}

/// Turns an ISO-3166 alpha-2 code into its flag emoji (regional indicators).
String? countryFlagEmoji(String? iso2) {
  final String? code = iso2?.toUpperCase();
  if (code == null || code.length != 2) return null;
  final int a = code.codeUnitAt(0);
  final int b = code.codeUnitAt(1);
  if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return null;
  return String.fromCharCode(0x1F1E6 + (a - 0x41)) +
      String.fromCharCode(0x1F1E6 + (b - 0x41));
}
