import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/radar/ipv6.dart';
import 'package:nova_client/src/features/radar/scanner.dart';
import 'package:nova_client/src/features/radar/sources.dart';

/// Field report, 2026-10-04: on the MCI firewall fragmentation is fully
/// blocked, UDP to Cloudflare is blocked, and the six-packet WebSocket cap is
/// applied to IPv4 only. IPv6 was named as one of three surviving routes, so an
/// address on it is a way back onto a Cloudflare-fronted server from a network
/// where the IPv4 one is capped.
///
/// None of this can be dialled from the machine it was written on, which has no
/// global IPv6 at all. So the arithmetic is tested rather than the reachability,
/// and the reachability is gated at runtime on there being an address to dial
/// from, which is the honest division.
void main() {
  group('address arithmetic', () {
    test('round-trips through 128 bits', () {
      for (final String a in <String>[
        '2606:4700::1',
        '2400:cb00:ffff:ffff:ffff:ffff:ffff:ffff',
        '2a06:98c0::',
      ]) {
        expect(Ipv6.fromBigInt(Ipv6.toBigInt(a)!), a);
      }
    });

    test('an IPv4 address is not a v6 one', () {
      expect(Ipv6.toBigInt('104.16.0.1'), isNull);
      expect(Ipv6.toBigInt('nonsense'), isNull);
    });

    test('a /32 holds 2^96 addresses and starts where it says', () {
      final (BigInt base, BigInt count) = Ipv6.parseCidr('2606:4700::/32')!;
      expect(Ipv6.fromBigInt(base), '2606:4700::');
      expect(count, BigInt.two.pow(96));
    });

    test('a base with host bits set is masked down to the network', () {
      final (BigInt base, BigInt _) = Ipv6.parseCidr('2606:4700::dead:beef/32')!;
      expect(Ipv6.fromBigInt(base), '2606:4700::');
    });

    test('a /29 is wider than a /32, which is the point of parsing it', () {
      final (BigInt _, BigInt wide) = Ipv6.parseCidr('2a06:98c0::/29')!;
      final (BigInt _, BigInt narrow) = Ipv6.parseCidr('2606:4700::/32')!;
      expect(wide > narrow, isTrue);
      expect(wide, BigInt.two.pow(99));
    });

    test('rejects what is not a v6 CIDR', () {
      expect(Ipv6.parseCidr('104.16.0.0/13'), isNull);
      expect(Ipv6.parseCidr('2606:4700::/129'), isNull);
      expect(Ipv6.parseCidr('2606:4700::'), isNull);
    });
  });

  group('sampling', () {
    test('every sample falls inside the range it came from', () {
      final (BigInt base, BigInt count) = Ipv6.parseCidr('2606:4700::/32')!;
      final List<String> got =
          Ipv6.sample(<String>['2606:4700::/32'], 50, rng: Random(1));
      expect(got, hasLength(50));
      for (final String a in got) {
        final BigInt v = Ipv6.toBigInt(a)!;
        expect(v > base, isTrue, reason: '$a is at or below the network address');
        expect(v < base + count, isTrue, reason: '$a is past the range');
      }
    });

    test('samples spread rather than cluster', () {
      // A filter that has learned one address has learned its neighbours, so
      // drawing 200 from 2^96 should not keep landing in the same corner.
      final List<String> got =
          Ipv6.sample(<String>['2606:4700::/32'], 200, rng: Random(7));
      expect(got.toSet(), hasLength(got.length), reason: 'duplicates drawn');
      final BigInt lo = got.map(Ipv6.toBigInt).map((b) => b!).reduce(
          (BigInt a, BigInt b) => a < b ? a : b);
      final BigInt hi = got.map(Ipv6.toBigInt).map((b) => b!).reduce(
          (BigInt a, BigInt b) => a > b ? a : b);
      expect(hi - lo > BigInt.two.pow(90), isTrue,
          reason: 'the draws sit in one corner of a 2^96 space');
    });

    test('draws from every range it is given', () {
      final List<String> got = Ipv6.sample(Ipv6.fallbackCidrs, 70, rng: Random(3));
      final Set<String> prefixes =
          got.map((String a) => a.split(':').first).toSet();
      expect(prefixes.length, greaterThan(3),
          reason: 'one range supplying everything means the spread is broken');
    });

    test('a range too small to sample is skipped, not crashed on', () {
      expect(Ipv6.sample(<String>['2606:4700::/128'], 5), isEmpty);
      expect(Ipv6.sample(<String>['104.16.0.0/13'], 5), isEmpty);
      expect(Ipv6.sample(<String>[], 5), isEmpty);
      expect(Ipv6.sample(<String>['2606:4700::/32'], 0), isEmpty);
    });
  });

  group('what counts as dialable', () {
    test('global addresses do', () {
      expect(Ipv6.isGlobal('2606:4700::1'), isTrue);
      expect(Ipv6.isGlobal('2400:cb00::1'), isTrue);
    });

    test('addresses that cannot reach Cloudflare do not', () {
      expect(Ipv6.isGlobal('::1'), isFalse, reason: 'loopback');
      expect(Ipv6.isGlobal('::'), isFalse, reason: 'unspecified');
      expect(Ipv6.isGlobal('fe80::1'), isFalse, reason: 'link-local');
      expect(Ipv6.isGlobal('fd00::1'), isFalse, reason: 'unique-local');
      expect(Ipv6.isGlobal('fc00::1'), isFalse, reason: 'unique-local');
      expect(Ipv6.isGlobal('104.16.0.1'), isFalse, reason: 'not v6 at all');
    });
  });

  test('availability answers for the machine it runs on', () async {
    // Not asserted either way: it is a property of the network, and this is
    // here so the call is exercised rather than only compiled.
    expect(await Ipv6.available(), isA<bool>());
  });

  group('what a scan will actually try', () {
    final CandidatePool pool = CandidatePool(
      <String>['104.16.0.0/13'],
      <String>['104.17.0.1'],
      cidrs6: <String>['2606:4700::/32'],
    );

    test('with IPv6 available, v6 addresses are in the list', () {
      final List<String> got = buildCandidates(pool, 40, hasIpv6: true);
      final List<String> v6 =
          got.where((String a) => a.contains(':')).toList();
      expect(v6, isNotEmpty,
          reason: 'the whole point is reaching Cloudflare where v4 is capped');
      for (final String a in v6) {
        expect(Ipv6.isGlobal(a), isTrue, reason: '$a cannot be dialled');
      }
    });

    test('without it, none are, because every probe would time out', () {
      final List<String> got = buildCandidates(pool, 40, hasIpv6: false);
      expect(got.where((String a) => a.contains(':')), isEmpty);
      expect(got, isNotEmpty, reason: 'the v4 scan must still happen');
    });

    test('IPv4 is still the bulk of the scan', () {
      final List<String> got = buildCandidates(pool, 40, hasIpv6: true);
      final int v6 = got.where((String a) => a.contains(':')).length;
      expect(v6 * 2, lessThan(got.length),
          reason: 'v4 works on most networks; v6 must not crowd it out');
    });

    test('with no v6 source, the built-in ranges are used', () {
      final CandidatePool bare =
          CandidatePool(<String>['104.16.0.0/13'], <String>[]);
      final List<String> got = buildCandidates(bare, 40, hasIpv6: true);
      expect(got.where((String a) => a.contains(':')), isNotEmpty,
          reason: 'a scan that cannot fetch a list is still worth running');
    });
  });

  test('the scan asks whether this device has IPv6 before scanning for it', () {
    // Structural, because start() reaches the network and cannot be run here.
    // The decision itself is covered above; what this catches is the gate being
    // removed from the one place that calls it, which is how buildCandidates
    // came to be extracted in the first place: deleting the IPv6 half of the
    // scan broke no test at all.
    final String src =
        File('lib/src/features/radar/scanner.dart').readAsStringSync();
    expect(src, contains('hasIpv6: await Ipv6.available()'),
        reason: 'scanning v6 without an address to dial from spends the whole '
            'budget on probes that cannot complete, and reports the network '
            'unreachable rather than saying it has no IPv6');
  });
}
