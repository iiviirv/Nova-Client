import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'secure_http.dart';

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
/// The DoH endpoints themselves are pinned to known IPs (see [_endpointIps]):
/// if we resolved cloudflare-dns.com / dns.google through the system resolver,
/// a network that blocks all plaintext DNS would kill the DoH tier before it
/// ever sends a query, leaving only the caller's static pinned IPs. Pinning the
/// endpoints (with the real hostname as SNI, so TLS still validates) keeps DoH
/// working as a live fallback even when system DNS is fully down.
///
/// Best-effort: if every DoH endpoint is unreachable this returns an empty
/// list and the caller falls back to the system resolver, so behaviour on an
/// open network is unchanged.
class DohResolver {
  DohResolver({http.Client? client})
      : _client = client ?? buildSecureClient(_resolveEndpoint);

  final http.Client _client;

  // RFC 8484 JSON-form endpoints. Different anycast operators, so a network
  // that blocks one may still allow the other; we try them in order.
  static const List<String> _endpoints = <String>[
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
  ];

  // Pinned IPs for the DoH endpoints, so the query can be sent even when system
  // DNS is fully blocked. TLS still validates the real endpoint hostname.
  static const Map<String, List<String>> _endpointIps = <String, List<String>>{
    'cloudflare-dns.com': <String>['104.16.248.249', '104.16.249.249'],
    'dns.google': <String>['8.8.8.8', '8.8.4.4'],
  };

  /// Dial IP for a DoH endpoint request: system resolver first (an open network
  /// stays exactly as before, and picks up IP rotation), then a pinned endpoint
  /// IP so a blocked resolver still connects.
  static Future<InternetAddress> _resolveEndpoint(Uri uri) async {
    final InternetAddress? literal = InternetAddress.tryParse(uri.host);
    if (literal != null) return literal;
    try {
      final List<InternetAddress> sys = await InternetAddress
          .lookup(uri.host)
          .timeout(const Duration(seconds: 3));
      for (final InternetAddress a in sys) {
        if (a.type == InternetAddressType.IPv4) return a;
      }
    } catch (_) {
      // Blocked/slow; fall through to the pinned endpoint IP.
    }
    final List<String>? pinned = _endpointIps[uri.host];
    if (pinned != null && pinned.isNotEmpty) return InternetAddress(pinned.first);
    final List<InternetAddress> again = await InternetAddress.lookup(uri.host);
    return again.firstWhere(
        (InternetAddress a) => a.type == InternetAddressType.IPv4,
        orElse: () => again.first);
  }

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
