import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves A records over DNS-over-HTTPS.
///
/// Nova's fallback proxy hosts (novaproxy.online and any siblings) are reached
/// by hostname, and censored networks poison plaintext DNS for exactly those
/// names: the emulator and real-device reports both surface as
/// `SocketException: Failed host lookup: 'novaproxy.online'`. Resolving the
/// name over HTTPS (to a resolver the network can't selectively poison) returns
/// the real Cloudflare IPs, which we then connect to directly while TLS still
/// validates the original hostname's certificate.
///
/// Best-effort: if every DoH endpoint is unreachable this returns an empty
/// list and the caller falls back to the system resolver, so behaviour on an
/// open network is unchanged.
class DohResolver {
  DohResolver({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // RFC 8484 JSON-form endpoints. Different anycast operators, so a network
  // that blocks one may still allow the other; we try them in order.
  static const List<String> _endpoints = <String>[
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
  ];
  static const Duration _timeout = Duration(seconds: 6);
  static const Duration _cacheTtl = Duration(minutes: 5);

  final Map<String, ({List<String> ips, DateTime at})> _cache =
      <String, ({List<String> ips, DateTime at})>{};

  /// IPv4 addresses for [host], or an empty list if none could be resolved.
  Future<List<String>> resolveA(String host) async {
    final ({List<String> ips, DateTime at})? hit = _cache[host];
    if (hit != null && DateTime.now().difference(hit.at) < _cacheTtl) {
      return hit.ips;
    }
    for (final String endpoint in _endpoints) {
      try {
        final List<String> ips = await _query(endpoint, host).timeout(_timeout);
        if (ips.isNotEmpty) {
          _cache[host] = (ips: ips, at: DateTime.now());
          return ips;
        }
      } catch (_) {
        // Try the next endpoint.
      }
    }
    return const <String>[];
  }

  Future<List<String>> _query(String endpoint, String host) async {
    final Uri uri = Uri.parse(endpoint)
        .replace(queryParameters: <String, String>{'name': host, 'type': 'A'});
    final http.Response r = await _client
        .get(uri, headers: <String, String>{'accept': 'application/dns-json'});
    if (r.statusCode < 200 || r.statusCode >= 300) return const <String>[];
    final dynamic body = jsonDecode(r.body.isEmpty ? '{}' : r.body);
    if (body is! Map) return const <String>[];
    final dynamic answers = body['Answer'];
    if (answers is! List) return const <String>[];
    final List<String> out = <String>[];
    for (final dynamic a in answers) {
      // DNS record type 1 == A (an IPv4 address in `data`).
      if (a is Map && a['type'] == 1) {
        final dynamic data = a['data'];
        if (data is String && _looksIpv4(data)) out.add(data);
      }
    }
    return out;
  }

  static bool _looksIpv4(String s) {
    final List<String> parts = s.split('.');
    if (parts.length != 4) return false;
    for (final String p in parts) {
      final int? n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }
}
