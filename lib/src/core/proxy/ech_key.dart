import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../logging/nova_log.dart';
import 'dns_https_record.dart';
import 'ech_spec.dart';

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

  /// Resolvers to try, in order, before giving up.
  ///
  /// One was not enough. A tester on a fresh phone got no key at all: the
  /// single DoH endpoint did not answer on his network, Nova fell back to the
  /// built-in key, and every connection failed. Different networks block
  /// different things, so this tries a second provider and then plain DNS
  /// before concluding there is no key to be had.
  static const List<String> kResolvers = <String>[
    'https://1.1.1.1/dns-query',
    'https://dns.google/resolve',
    'udp://1.1.1.1',
    'udp://8.8.8.8',
  ];

  /// The key to put in a config now, or null when there is none to be had.
  ///
  /// Null matters and is not a detail. A key that cannot be vouched for is
  /// worse than no ECH at all: Cloudflare rotates this value, and a stale one
  /// does not degrade, it fails every single connection on the profile with a
  /// certificate for cloudflare-ech.com. An earlier version of this returned
  /// the built-in key when it could not fetch one, which is precisely how a
  /// tester ended up unable to connect on a brand new phone. The caller must
  /// turn ECH off for the connection rather than send a guess.
  ///
  /// [spec] is where to look, which the user can change. A different spec is a
  /// different answer, so changing it drops what was remembered rather than
  /// serving a key fetched from somewhere the user no longer asked about.
  static Future<String?> current({
    EchSpec spec = EchSpec.fallback,
    DateTime? now,
    Future<String?> Function()? fetch,
  }) async {
    final DateTime at = now ?? DateTime.now();
    if (_fresh(at, spec)) return _memory!;
    await _loadCache();
    if (_fresh(at, spec)) return _memory!;
    final String? fresh = await (fetch ?? () => _lookupAnywhere(spec))();
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
    // Nothing fresh. A cached key for this same lookup is still worth using:
    // it was real when it was fetched and Cloudflare keeps old keys working for
    // a while. A key fetched for a different lookup is not, and neither is the
    // built-in one, which is older than anything and is why this used to fail.
    if (_memory != null && _memoryFor == spec.cacheKey) return _memory!;
    NovaLog.instance.write(
        'Could not get an ECH key from any resolver, so this connection goes '
        'out without ECH rather than with a key that would be refused.');
    return null;
  }

  /// The first resolver that answers, starting with the one the user chose.
  static Future<String?> _lookupAnywhere(EchSpec spec) async {
    final List<String> tried = <String>[
      spec.resolver,
      ...kResolvers.where((String r) => r != spec.resolver),
    ];
    for (final String r in tried) {
      final String? k = await DnsHttpsRecord.lookup(spec.domain, r);
      if (k != null && k.isNotEmpty) {
        if (r != spec.resolver) {
          NovaLog.instance.write(
              'The ECH key did not come from ${spec.resolver}; got it from $r '
              'instead.');
        }
        return k;
      }
    }
    return null;
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
