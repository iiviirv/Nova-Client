import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/nova_log.dart';
import 'singbox/singbox_config.dart';

/// Cloudflare's current ECH key, fetched rather than believed.
///
/// This exists because shipping the key as a constant broke every ECH config
/// in the field. Cloudflare rotates it; a tester had ECH working for about two
/// hours and then nothing connected at all, on filtered and unfiltered networks
/// alike, while another client kept working because it reads the key from DNS
/// on every connection. The log says it exactly: "certificate is valid for
/// cloudflare-ech.com, not `the real host`", which is what a server does when
/// it cannot decrypt the inner hello and falls back to its public name.
///
/// So the key is looked up, cached, and persisted, with the built-in value as
/// the floor rather than the source. A stale key is worse than no ECH: it does
/// not degrade, it fails every connection on the profile.
abstract final class EchKey {
  /// Cloudflare's DoH endpoint by address, so this needs no name resolved
  /// before it can resolve a name, and rides 443 where plain DNS is blocked.
  static const String kDohUrl = 'https://1.1.1.1/dns-query';

  /// The name whose key every Cloudflare zone publishes.
  static const String kEchDomain = 'cloudflare-ech.com';

  static const String _prefKey = 'nova.ech.key';
  static const String _prefAt = 'nova.ech.fetchedAt';

  /// How long a fetched key is trusted before being looked up again. Short,
  /// because the cost of being wrong is every connection on the profile and
  /// the cost of being right is one DNS query over HTTPS.
  static const Duration maxAge = Duration(hours: 6);

  static String? _memory;
  static DateTime? _memoryAt;

  /// The key to put in a config now: the freshest one available, never null.
  static Future<String> current({
    DateTime? now,
    Future<String?> Function()? fetch,
  }) async {
    final DateTime at = now ?? DateTime.now();
    if (_memory != null &&
        _memoryAt != null &&
        at.difference(_memoryAt!) < maxAge) {
      return _memory!;
    }
    await _loadCache();
    if (_memory != null &&
        _memoryAt != null &&
        at.difference(_memoryAt!) < maxAge) {
      return _memory!;
    }
    final String? fresh = await (fetch ?? _fetchOverDoh)();
    if (fresh != null && fresh.isNotEmpty) {
      if (fresh != _memory) {
        NovaLog.instance.write(
            'Cloudflare published a new ECH key; configs using ECH will use it '
            'from the next connection.');
      }
      _memory = fresh;
      _memoryAt = at;
      await _saveCache(fresh, at);
      return fresh;
    }
    // Nothing fresh. A cached key, however old, beats the built-in one, which
    // is only a floor so that a first run with no network still has something.
    return _memory ?? kCloudflareEchConfig;
  }

  /// Drops what is remembered, so the next [current] looks the key up again.
  /// Used when a connection fails the way a stale key makes it fail.
  static Future<void> invalidate() async {
    _memory = null;
    _memoryAt = null;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.remove(_prefKey);
      await p.remove(_prefAt);
    } catch (_) {
      // Nothing to do: the in-memory copy is already gone.
    }
  }

  static Future<void> _loadCache() async {
    if (_memory != null) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? k = p.getString(_prefKey);
      final int? ms = p.getInt(_prefAt);
      if (k != null && k.isNotEmpty && ms != null) {
        _memory = k;
        _memoryAt = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {
      // Tests and first runs have no store; the fetch covers both.
    }
  }

  static Future<void> _saveCache(String key, DateTime at) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_prefKey, key);
      await p.setInt(_prefAt, at.millisecondsSinceEpoch);
    } catch (_) {
      // Not being able to persist costs one lookup next launch, nothing more.
    }
  }

  /// The ECH value out of the HTTPS record, over DoH.
  static Future<String?> _fetchOverDoh() async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final Uri u = Uri.parse('$kDohUrl?name=$kEchDomain&type=HTTPS');
      final HttpClientRequest req = await client.getUrl(u);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final HttpClientResponse res =
          await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final String body = await res.transform(utf8.decoder).join();
      return parseEch(body);
    } catch (e) {
      NovaLog.instance
          .write('Could not refresh the ECH key ($e); using the saved one.');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The `ech=` value in a DoH JSON answer, or null when there is none.
  ///
  /// Separated from the request so it can be tested without a network, which
  /// matters: the shape of this answer is the only thing standing between a
  /// rotated key and every ECH config failing again.
  static String? parseEch(String dohJson) {
    try {
      final Object? decoded = jsonDecode(dohJson);
      if (decoded is! Map<String, dynamic>) return null;
      final Object? answers = decoded['Answer'];
      if (answers is! List) return null;
      for (final Object? a in answers) {
        if (a is! Map) continue;
        final Object? data = a['data'];
        if (data is! String) continue;
        for (final String part in data.split(RegExp(r'\s+'))) {
          if (part.startsWith('ech=')) {
            final String v = part.substring(4).trim();
            if (v.isNotEmpty) return v;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
