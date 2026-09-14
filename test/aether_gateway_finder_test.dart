import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

/// Finding a gateway that carries traffic without the user retrying by hand.
///
/// The behaviour under test is the one a tester described from Iran: MASQUE
/// finds an address, the tunnel does not come up, and the only remedy offered
/// is running the scan again. A re-scan that does not exclude the dead address
/// tends to return it again, so the retry is a coin flip.
void main() {
  AetherJobStatus done(Map<String, dynamic> r) =>
      AetherJobStatus(AetherJobState.done, result: r);
  AetherJobStatus failed(String e) =>
      AetherJobStatus(AetherJobState.failed, error: e);

  test('the first gateway works, and nothing extra is spent', () async {
    int scans = 0, verifies = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, __) async {
        scans++;
        return done(<String, dynamic>{'endpoint': '162.159.198.1:443'});
      },
      verify: (_, __) async {
        verifies++;
        return done(<String, dynamic>{});
      },
    );
    final AetherFindResult r = await f.find(const AetherOptions());
    expect(r.ok, isTrue);
    expect(r.endpoint, '162.159.198.1:443');
    expect(r.attempts, 1);
    expect(scans, 1);
    expect(verifies, 1);
    expect(f.verified, <String>['162.159.198.1:443']);
  });

  test('a dead gateway is excluded and the next one is tried', () async {
    // The whole point. Without the exclusion the second scan returns the same
    // dead address and the loop achieves nothing.
    final List<List<String>> excludedSeen = <List<String>>[];
    final List<String> found = <String>['1.1.1.1:443', '2.2.2.2:443'];
    int i = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, List<String> excluded) async {
        excludedSeen.add(List<String>.of(excluded));
        return done(<String, dynamic>{'endpoint': found[i++]});
      },
      verify: (_, String e) async =>
          e == '2.2.2.2:443' ? done(<String, dynamic>{}) : failed('no traffic'),
    );
    final AetherFindResult r = await f.find(const AetherOptions());
    expect(r.ok, isTrue);
    expect(r.endpoint, '2.2.2.2:443');
    expect(r.attempts, 2);
    expect(excludedSeen.first, isEmpty);
    expect(excludedSeen[1], <String>['1.1.1.1:443'],
        reason: 'a re-scan that does not exclude the dead address returns it '
            'again, which is what makes the manual retry a coin flip');
    expect(r.rejected, <String>['1.1.1.1:443']);
  });

  test('it gives up after the attempt budget instead of spinning', () async {
    int scans = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      attempts: 3,
      scan: (_, __) async {
        scans++;
        return done(<String, dynamic>{'endpoint': '9.9.9.$scans:443'});
      },
      verify: (_, __) async => failed('no traffic'),
    );
    final AetherFindResult r = await f.find(const AetherOptions());
    expect(r.ok, isFalse);
    expect(scans, 3);
    expect(r.attempts, 3);
    expect(r.error, 'no traffic');
    expect(r.rejected.length, 3);
  });

  test('a scan that finds nothing stops rather than burning the budget',
      () async {
    // Excluding one more address cannot help a scan that found none, so
    // retrying is only a longer wait before the same answer.
    int scans = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, __) async {
        scans++;
        return failed('no gateway answered');
      },
      verify: (_, __) async => done(<String, dynamic>{}),
    );
    final AetherFindResult r = await f.find(const AetherOptions());
    expect(r.ok, isFalse);
    expect(scans, 1, reason: 'retrying a scan that found nothing is just a wait');
    expect(r.error, 'no gateway answered');
  });

  test('a scan that returns an empty address is a failure, not a tunnel to nowhere',
      () async {
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, __) async => done(<String, dynamic>{'endpoint': ''}),
      verify: (_, __) async => done(<String, dynamic>{}),
    );
    final AetherFindResult r = await f.find(const AetherOptions());
    expect(r.ok, isFalse);
    expect(r.error, contains('no address'));
  });

  test('verified gateways are kept for later, not discarded', () async {
    // Keeping them is what lets a later connection fall back instead of
    // starting the whole search again.
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, __) async => done(<String, dynamic>{'endpoint': '5.5.5.5:443'}),
      verify: (_, __) async => done(<String, dynamic>{}),
    );
    await f.find(const AetherOptions());
    await f.find(const AetherOptions());
    expect(f.verified, <String>['5.5.5.5:443'],
        reason: 'the same address should be remembered once, not twice');
  });
}
