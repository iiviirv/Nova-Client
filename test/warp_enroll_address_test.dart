import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';

/// Field log, 2026-10-10, on a network where another client registered fine:
///
///     registration did not go through directly
///     did not go through behind ECH
///     trying over camouflaged routes, which can take a few minutes
///     identity failed after 136983ms: api.cloudflareclient.com did not
///     answer within 20s
///
/// The other client had a tunnel to dial through and Nova had none. With no
/// tunnel the only lever left is which address is dialled: the core keeps the
/// server name and the HTTP host as api.cloudflareclient.com and opens the
/// connection wherever it is told, so a blocked address for that one name need
/// not be the end of it.
void main() {
  test('the addresses come from the ranges the core itself dials', () {
    // Not invented. Every one has to fall inside a range the scanner uses, so
    // these are addresses WARP actually answers on.
    final List<String> v4 = kAetherDirectCidrs
        .where((String c) => !c.contains(':'))
        .map((String c) => c.split('/').first)
        .map((String a) => a.substring(0, a.lastIndexOf('.')))
        .toList();
    for (final String ip in kAetherEnrollAddresses) {
      final String prefix = ip.substring(0, ip.lastIndexOf('.'));
      expect(v4, contains(prefix),
          reason: '$ip is not in any range the core scans, so there is no '
              'reason to think Cloudflare answers there');
    }
  });

  test('they are addresses, never names', () {
    for (final String ip in kAetherEnrollAddresses) {
      expect(InternetAddress.tryParse(ip), isNotNull,
          reason: 'the whole point is to skip the lookup that is being '
              'interfered with, so a name here would defeat it');
      expect(InternetAddress.tryParse(ip)!.type, InternetAddressType.IPv4);
    }
  });

  test('the list is short, because each one costs a budget', () {
    expect(kAetherEnrollAddresses, isNotEmpty);
    expect(kAetherEnrollAddresses.length, lessThanOrEqualTo(4),
        reason: 'if three Cloudflare edges will not answer then the network '
            'is not blocking an address, it is blocking Cloudflare, and more '
            'attempts only make the user wait');
    expect(kAetherEnrollAddresses.toSet().length,
        kAetherEnrollAddresses.length);
  });

  test('the first is the one the evidence names', () {
    // Both the core's own help text and the field notes out of Iran name this
    // range as a clean edge.
    expect(kAetherEnrollAddresses.first, startsWith('188.114.97.'));
  });

  group('the ladder', () {
    final String src =
        File('lib/src/features/servers/aether_gateway_search.dart')
            .readAsStringSync();

    test('tries a clean address before the slow camouflaged routes', () {
      final int clean = src.indexOf('behind ECH to a clean Cloudflare address');
      final int camo = src.indexOf('over camouflaged routes');
      expect(clean, greaterThan(-1));
      expect(clean, lessThan(camo),
          reason: 'camouflage takes minutes and in recent testing got through '
              'on no network at all, so it stays last');
    });

    test('only that rung redirects the API', () {
      // The others must keep meaning what they have always meant: a failure
      // there is a failure to reach Cloudflare the ordinary way.
      expect(src, contains('kAetherEnrollAddresses.first'));
      expect(
          RegExp(r'setEnrollAddress\(null\)').allMatches(src).length,
          greaterThanOrEqualTo(1),
          reason: 'it is process-wide, so it has to be cleared after the rung '
              'that asked for it');
    });
  });
}
