import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/nova_log.dart';
import 'dns_https_record.dart';
import 'ech_spec.dart';
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
  static const String _prefKey = 'nova.ech.key';
  static const String _prefAt = 'nova.ech.fetchedAt';
  static const String _prefFor = 'nova.ech.spec';

  /// How long a fetched key is trusted before being looked up again. Short,
  /// because the cost of being wrong is every connection on the profile and
  /// the cost of being right is one DNS query over HTTPS.
  static const Duration maxAge = Duration(hours: 6);

  static String? _memory;
  static DateTime? _memoryAt;
  static String? _memoryFor;

  /// The key to put in a config now: the freshest one available, never null.
  ///
  /// [spec] is where to look, which the user can change. A different spec is a
  /// different answer, so changing it drops what was remembered rather than
  /// serving a key fetched from somewhere the user no longer asked about.
  static Future<String> current({
    EchSpec spec = EchSpec.fallback,
    DateTime? now,
    Future<String?> Function()? fetch,
  }) async {
    final DateTime at = now ?? DateTime.now();
    if (_fresh(at, spec)) return _memory!;
    await _loadCache();
    if (_fresh(at, spec)) return _memory!;
    final String? fresh =
        await (fetch ?? () => DnsHttpsRecord.lookup(spec.domain, spec.resolver))();
    if (fresh != null && fresh.isNotEmpty) {
      if (fresh != _memory) {
        NovaLog.instance.write(
            'Cloudflare published a new ECH key; configs using ECH will use it '
            'from the next connection.');
      }
      _memory = fresh;
      _memoryAt = at;
      _memoryFor = spec.cacheKey;
      await _saveCache(fresh, at, spec);
      return fresh;
    }
    // Nothing fresh. A cached key, however old, beats the built-in one, which
    // is only a floor so that a first run with no network still has something.
    // Only if it came from the same place: a key fetched for a different spec
    // answers a question the user is no longer asking.
    if (_memory != null && _memoryFor == spec.cacheKey) return _memory!;
    return kCloudflareEchConfig;
  }

  static bool _fresh(DateTime at, EchSpec spec) =>
      _memory != null &&
      _memoryAt != null &&
      _memoryFor == spec.cacheKey &&
      at.difference(_memoryAt!) < maxAge;

  /// Drops what is remembered, so the next [current] looks the key up again.
  /// Used when a connection fails the way a stale key makes it fail.
  static Future<void> invalidate() async {
    _memory = null;
    _memoryAt = null;
    _memoryFor = null;
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
        _memoryFor = p.getString(_prefFor);
      }
    } catch (_) {
      // Tests and first runs have no store; the fetch covers both.
    }
  }

  static Future<void> _saveCache(String key, DateTime at, EchSpec spec) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_prefKey, key);
      await p.setInt(_prefAt, at.millisecondsSinceEpoch);
      await p.setString(_prefFor, spec.cacheKey);
    } catch (_) {
      // Not being able to persist costs one lookup next launch, nothing more.
    }
  }

  /// The `ech=` value in a DoH JSON answer, or null when there is none.
  ///
  /// Separated from the request so it can be tested without a network, which
  /// matters: the shape of this answer is the only thing standing between a
  /// rotated key and every ECH config failing again.
  static String? parseEch(String dohJson) =>
      DnsHttpsRecord.parseJsonAnswer(dohJson);
}
