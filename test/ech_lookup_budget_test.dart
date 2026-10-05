import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/ech_key.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';

/// Field report, Windows 1.30.1: server testing "does not work, you have to
/// pick one at random and connect", and the tunnel "still drops after a few
/// hours" until a different resolver is typed in by hand.
///
/// Two causes, both measured rather than guessed. The resolver chain had a
/// per-try timeout of eight seconds (8011ms against a blackhole, every time),
/// ten resolvers, run one after another, and no total budget: up to eighty
/// seconds of a user waiting before a connect or a measurement could start.
/// And the desktop controller never topped the key up through a working
/// tunnel, so after the six-hour expiry it looked the key up again with the
/// tunnel down, on the network that was blocking the lookup.
void main() {
  group('the chain is bounded', () {
    test('a per-resolver slice far shorter than a DNS answer needs', () {
      expect(EchKey.perResolver.inMilliseconds, lessThanOrEqualTo(3000),
          reason: 'eight seconds times ten resolvers is eighty seconds');
      expect(EchKey.perResolver.inMilliseconds, greaterThanOrEqualTo(1000),
          reason: 'too short and a slow but working resolver is discarded');
    });

    test('a total budget a waiting user can sit through', () {
      expect(EchKey.lookupBudget.inSeconds, lessThanOrEqualTo(15));
      // The whole point: the budget, not the resolver count, decides the wait.
      expect(
          EchKey.lookupBudget,
          lessThan(EchKey.perResolver * EchKey.kResolvers.length),
          reason: 'otherwise the budget never bites and the chain is unbounded '
              'again');
    });

    test('the background top-up gets longer, since nobody waits on it', () {
      expect(EchKey.backgroundBudget, greaterThan(EchKey.lookupBudget));
    });

    test('every resolver dead: it gives up inside the budget', () async {
      // Ten addresses in TEST-NET-1, which routes nowhere, so this exercises
      // the budget and not any real resolver's behaviour. The real list is
      // reachable from any machine a test runs on, which is why the seam
      // exists.
      final List<String> dead = <String>[
        for (int i = 1; i <= 10; i++) 'udp://192.0.2.$i',
      ];
      final Stopwatch w = Stopwatch()..start();
      final String? got = await EchKey.lookupChainForTest(
        const EchSpec(
            domain: 'cloudflare-ech.com', resolver: 'udp://192.0.2.1'),
        resolvers: dead,
      );
      w.stop();
      expect(got, isNull);
      expect(w.elapsed,
          lessThan(EchKey.lookupBudget + const Duration(seconds: 4)),
          reason: 'took ${w.elapsed.inSeconds}s. Ten resolvers at the old '
              'eight-second timeout was eighty seconds of a user waiting');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('it stops asking once the budget is spent, rather than asking all ten',
        () async {
      // Twelve sockets that receive queries and never answer, so every attempt
      // costs a full slice. Distinct ports rather than 127.0.0.N addresses:
      // macOS does not route the loopback aliases without an ifconfig alias,
      // so an address-based version of this counted one query and would have
      // passed for the wrong reason.
      //
      // Counting what arrives is the only way to tell "gave up on the budget"
      // apart from "every attempt failed instantly", which is what a negative
      // timeout does.
      int queries = 0;
      final List<RawDatagramSocket> sinks = <RawDatagramSocket>[];
      for (int i = 0; i < 12; i++) {
        final RawDatagramSocket s =
            await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        s.listen((RawSocketEvent e) {
          if (e != RawSocketEvent.read) return;
          if (s.receive() != null) queries++;
        });
        sinks.add(s);
      }
      try {
        final List<String> dead = <String>[
          for (final RawDatagramSocket s in sinks) 'udp://127.0.0.1:${s.port}',
        ];
        final Stopwatch w = Stopwatch()..start();
        final String? got = await EchKey.lookupChainForTest(
          EchSpec(domain: 'cloudflare-ech.com', resolver: dead.first),
          resolvers: dead,
          budget: const Duration(seconds: 5),
          perTry: const Duration(seconds: 1),
        );
        w.stop();
        expect(got, isNull);
        // Five seconds of one-second slices is about five attempts, not twelve.
        expect(queries, lessThan(12),
            reason: 'asked $queries times in ${w.elapsedMilliseconds}ms; the '
                'budget has to stop the chain, not merely clamp each try');
        expect(queries, greaterThan(1),
            reason: 'it must work through the list rather than give up on the '
                'first failure');
      } finally {
        for (final RawDatagramSocket s in sinks) {
          s.close();
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a resolver that answers is still used, budget or no budget',
        () async {
      // The first two are dead, the third is the real one. This is the shape
      // the field report describes: udp://1.1.1.1 not answering while
      // udp://1.0.0.1 does.
      final Stopwatch w = Stopwatch()..start();
      final String? got = await EchKey.lookupChainForTest(
        const EchSpec(
            domain: 'cloudflare-ech.com', resolver: 'udp://192.0.2.1'),
        resolvers: <String>[
          'udp://192.0.2.2',
          'udp://1.0.0.1',
        ],
      );
      w.stop();
      expect(got, isNotNull,
          reason: 'the budget must not cut off a working fallback');
      expect(got, isNotEmpty);
      expect(w.elapsed, lessThan(EchKey.lookupBudget),
          reason: 'two dead resolvers then a live one, inside the budget');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  /// Both controllers have to top the key up through the tunnel. This work has
  /// now been fixed one-controller-at-a-time five times: _stopPsiphon, the
  /// opportunistic WARP registration, the ECH lookup wiring, the measuring
  /// key, and this.
  test('both controllers top the ECH key up through a working tunnel', () {
    for (final String path in <String>[
      'lib/src/core/proxy/singbox_proxy_controller.dart',
      'lib/src/core/proxy/desktop_proxy_controller.dart',
    ]) {
      expect(
          File(path).readAsStringSync(),
          contains('EchKey.refreshThroughTunnel'),
          reason: '$path never refreshes the key while a tunnel is up, so on '
              'that platform the key expires and is then looked up on the '
              'network that was blocking the lookup');
    }
  });

  test('the desktop measure path says when it is testing without ECH', () {
    final String src =
        File('lib/src/core/proxy/desktop_proxy_controller.dart')
            .readAsStringSync();
    expect(src, contains('Testing without ECH'),
        reason: 'a list of ECH-only servers came back entirely dead with no '
            'reason given anywhere');
  });
}
