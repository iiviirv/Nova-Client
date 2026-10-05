import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// The public name the remembered key belongs to, so a refusal naming that
  /// name can be recognised as this key being refused.
  static String? _memoryDomain;

  /// Resolvers to try, in order, before giving up.
  ///
  /// One was not enough. A tester on a fresh phone got no key at all: the
  /// single DoH endpoint did not answer on his network, Nova fell back to the
  /// built-in key, and every connection failed. Different networks block
  /// different things, so this tries a second provider and then plain DNS
  /// before concluding there is no key to be had.
  /// Deliberately a mixture. 1.1.1.1 and 8.8.8.8 are the two addresses most
  /// likely to be blocked outright precisely because everyone uses them, so
  /// the list also carries providers that are not those, and both transports.
  /// Every one of these was checked to actually return the key, not merely to
  /// exist. Quad9's DoH was dropped after it answered HTTP 505: it requires
  /// HTTP/2, which this client does not speak, so it would have been a slot
  /// that always failed while looking like a fallback.
  static const List<String> kResolvers = <String>[
    // Plain DNS to 1.1.1.1 first, which is not where this started. The order
    // used to put DoH first, on the assumption that UDP to Cloudflare was
    // blocked. A tester corrected that: every other client he tried does the
    // lookup as udp://1.1.1.1 or 1.0.0.1 and all of them work on the same
    // network where Nova's DoH call to 1.1.1.1 did not. The assumption came
    // from a report about UDP carrying tunnel traffic, which is a different
    // thing from a DNS query on port 53.
    'udp://1.1.1.1',
    'udp://1.0.0.1',
    'https://1.1.1.1/dns-query',
    'https://dns.google/resolve',
    'udp://8.8.8.8',
    'https://doh.opendns.com/dns-query',
    'https://dns.nextdns.io/dns-query',
    'https://doh.sb/dns-query',
    'https://dns.adguard-dns.com/dns-query',
    'udp://9.9.9.9',
  ];

  /// Fetch a key now and keep it, whatever the cache says.
  ///
  /// Called while a tunnel is already carrying traffic, which is the one moment
  /// the lookup is almost certain to succeed: it goes out through the tunnel
  /// rather than through whatever is blocking it. In Iran ECH is currently the
  /// only thing that connects at all, so "no key" is not a degraded state, it
  /// is no service. Topping the key up whenever a connection happens to be up
  /// is what keeps the next connection possible.
  static Future<void> refreshThroughTunnel(EchSpec spec) async {
    try {
      final String? fresh =
          await _lookupAnywhere(spec, budget: backgroundBudget);
      if (fresh == null || fresh.isEmpty) return;
      if (fresh != _memory) {
        NovaLog.instance.write(
            'Refreshed the ECH key through the tunnel; the next connection '
            'will use it.');
      }
      _memory = fresh;
      _memoryAt = DateTime.now();
      _memoryFor = spec.cacheKey;
      _memoryDomain = spec.domain;
      await _saveCache(fresh, _memoryAt!, spec);
    } catch (_) {
      // Nobody asked for this and the connection is already working.
    }
  }

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
      _memoryDomain = spec.domain;
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

  /// How long one resolver gets before the next is tried.
  ///
  /// Was eight seconds, the module default, and ten resolvers of that in a row
  /// is eighty seconds of a user waiting. Measured on a blackholed resolver:
  /// 8011ms, every time. A DNS answer that is coming arrives in well under a
  /// second, so a long per-try timeout buys nothing and costs the whole chain.
  static const Duration perResolver = Duration(seconds: 2, milliseconds: 500);

  /// How long the whole chain gets when someone is waiting for it.
  ///
  /// Field report from Windows: server testing "does not work, you have to
  /// pick one at random and connect". With no budget at all, a network that
  /// drops the first resolvers made both connecting and measuring sit for up
  /// to eighty seconds before anything else could happen.
  static const Duration lookupBudget = Duration(seconds: 12);

  /// The same chain with room to finish, for the background top-up through a
  /// tunnel that is already working. Nobody is waiting on that one.
  static const Duration backgroundBudget = Duration(seconds: 40);

  /// The first resolver that answers, starting with the one the user chose.
  ///
  /// Sequential on purpose. Asking ten resolvers at once would answer sooner
  /// on a bad network, but on a good one it would send ten plaintext queries
  /// for cloudflare-ech.com where one was needed, and that query is close to a
  /// signature for this kind of client. One query in the common case is worth
  /// more than a faster worst case.
  static Future<String?> _lookupAnywhere(
    EchSpec spec, {
    Duration? budget,
    Duration? perTry,
    List<String>? resolvers,
  }) async {
    final List<String> pool = resolvers ?? kResolvers;
    final List<String> tried = <String>[
      spec.resolver,
      ...pool.where((String r) => r != spec.resolver),
    ];
    final Stopwatch spent = Stopwatch()..start();
    final Duration total = budget ?? lookupBudget;
    for (final String r in tried) {
      final Duration left = total - spent.elapsed;
      if (left <= Duration.zero) {
        NovaLog.instance.write(
            'Gave up looking for the ECH key after ${total.inSeconds}s; the '
            'resolvers that answer on this network were not reached in time.',
            level: NovaLogLevel.warn);
        return null;
      }
      // Never hand a timeout that is not positive to the lookup. A negative
      // Duration makes it fail instantly rather than loudly, which looks
      // exactly like a resolver that does not answer and hides the fact that
      // the budget is what ran out.
      final Duration want = perTry ?? perResolver;
      final Duration slice = want < left ? want : left;
      final String? k =
          await DnsHttpsRecord.lookup(spec.domain, r, timeout: slice);
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

  /// The resolver chain with its list supplied, so a test can make every
  /// resolver unreachable and watch the budget bite. Without this the only
  /// list is the real one, which answers from any machine a test runs on, so
  /// the give-up path could not be reached at all.
  @visibleForTesting
  static Future<String?> lookupChainForTest(
    EchSpec spec, {
    required List<String> resolvers,
    Duration? budget,
    Duration? perTry,
  }) =>
      _lookupAnywhere(spec,
          resolvers: resolvers, budget: budget, perTry: perTry);

  static bool _fresh(DateTime at, EchSpec spec) =>
      _memory != null &&
      _memoryAt != null &&
      _memoryFor == spec.cacheKey &&
      at.difference(_memoryAt!) < maxAge;

  /// Whether a core log line is a server refusing the key we gave it.
  ///
  /// The signature is in this module's own doc comment: a server that cannot
  /// decrypt the inner hello falls back to its public name, so Go reports
  /// "certificate is valid for cloudflare-ech.com, not `the real host`".
  ///
  /// Pure and public so it can be tested against real log text rather than
  /// against itself.
  static bool looksLikeRefusedKey(String line, {String? domain}) {
    final String name = (domain ?? _memoryDomain ?? '').toLowerCase();
    if (name.isEmpty) return false;
    final String l = line.toLowerCase();
    return l.contains('certificate is valid for') && l.contains(name);
  }

  /// Drop the key when a core line says a server refused it.
  ///
  /// Without this the cache was a one-way door. [current] falls back to the
  /// remembered key when a fresh lookup fails, and nothing in the app ever
  /// called [invalidate], so a key that every server rejects stayed in use for
  /// its full six hours and across restarts. That is bad enough when
  /// Cloudflare has simply rotated; it is worse if the key was never
  /// Cloudflare's, because a key supplied by someone else decrypts to them.
  ///
  /// Returns whether it dropped anything, which is what a test can assert on.
  static Future<bool> noteCoreLine(String line) async {
    if (_memory == null) return false;
    if (!looksLikeRefusedKey(line)) return false;
    NovaLog.instance.write(
        'A server refused the ECH key, so it is being discarded and looked up '
        'again on the next connection.');
    await invalidate();
    return true;
  }

  /// Drops what is remembered, so the next [current] looks the key up again.
  /// Used when a connection fails the way a stale key makes it fail.
  static Future<void> invalidate() async {
    _memory = null;
    _memoryAt = null;
    _memoryFor = null;
    _memoryDomain = null;
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
