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

  /// A scan result in the shape the core actually returns.
  ///
  /// This used to be written as a plain string, and that is how a real bug got
  /// through every test here: the core returns
  /// {ip: ..., port: ..., rtt_ms: ...}, the finder called toString on it, and
  /// the result went to the core as a peer it refused and into the excluded
  /// list where it matched nothing. The fakes now use the real shape, so a test
  /// that passes here means something on a device.
  Map<String, dynamic> scanResult(String ip, int port) => <String, dynamic>{
        'endpoint': <String, dynamic>{'ip': ip, 'port': port, 'rtt_ms': 431},
      };
  AetherJobStatus failed(String e) =>
      AetherJobStatus(AetherJobState.failed, error: e);

  test('the first gateway works, and nothing extra is spent', () async {
    int scans = 0, verifies = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, __) async {
        scans++;
        return done(scanResult('162.159.198.1', 443));
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
    final List<List<Object>> found = <List<Object>>[
      <Object>['1.1.1.1', 443],
      <Object>['2.2.2.2', 443],
    ];
    int i = 0;
    final AetherGatewayFinder f = AetherGatewayFinder(
      scan: (_, List<String> excluded) async {
        excludedSeen.add(List<String>.of(excluded));
        final List<Object> f = found[i++];
        return done(scanResult(f[0] as String, f[1] as int));
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
        return done(scanResult('9.9.9.$scans', 443));
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
      scan: (_, __) async => done(scanResult('5.5.5.5', 443)),
      verify: (_, __) async => done(<String, dynamic>{}),
    );
    await f.find(const AetherOptions());
    await f.find(const AetherOptions());
    expect(f.verified, <String>['5.5.5.5:443'],
        reason: 'the same address should be remembered once, not twice');
  });

  group('verification reports what it found, not just that it ran', () {
    // The core answers {"reachable": <bool>} and the job succeeds either way.
    // The state says the check completed; the field says what it concluded.
    test('an unreachable gateway is rejected, not accepted', () async {
      // The bug a tester in Iran hit: a config that saved and then sat on
      // "verifying" until it was rebuilt by hand.
      int attempts = 0;
      final AetherGatewayFinder f = AetherGatewayFinder(
        attempts: 2,
        scan: (_, __) async {
          attempts++;
          return done(scanResult('9.9.9.$attempts', 443));
        },
        verify: (_, __) async =>
            done(<String, dynamic>{'reachable': false}),
      );
      final AetherFindResult r = await f.find(const AetherOptions());
      expect(r.ok, isFalse,
          reason: 'the core said the gateway was unreachable');
      expect(r.rejected.length, 2,
          reason: 'both should have been ruled out and excluded');
      expect(r.error, contains('carried no traffic'));
    });

    test('a reachable gateway is accepted', () async {
      final AetherGatewayFinder f = AetherGatewayFinder(
        scan: (_, __) async => done(scanResult('1.1.1.1', 443)),
        verify: (_, __) async => done(<String, dynamic>{'reachable': true}),
      );
      expect((await f.find(const AetherOptions())).ok, isTrue);
    });

    test('a verification with no verdict is still accepted', () async {
      // Older cores, or a call that returns nothing useful. Treating silence
      // as failure would reject every gateway on such a build; only an
      // explicit false is a rejection.
      final AetherGatewayFinder f = AetherGatewayFinder(
        scan: (_, __) async => done(scanResult('2.2.2.2', 443)),
        verify: (_, __) async => done(<String, dynamic>{}),
      );
      expect((await f.find(const AetherOptions())).ok, isTrue);
    });
  });
}
