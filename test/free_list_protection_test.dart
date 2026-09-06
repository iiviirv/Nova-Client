import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_fronting.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_store.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Protecting the free list from being read straight off a public URL.
///
/// The free subscription lives at a world-readable address, so a censor fetches
/// it in one request and blocks every address in it, and the servers stop
/// working within about two days. Nova's answer is to re-address that list
/// through addresses found on THIS network, spreading the best few at random so
/// no single address is shared by everyone and dies for everyone at once.
///
/// Two things had to be true for that to protect anyone, and neither was:
/// the re-addressing was off unless the user found the switch, and the pool it
/// reads was only ever filled by the Radar screen, so a user who never opened
/// Radar had an empty pool and it silently did nothing.
void main() {
  /// The store is a singleton that caches its SharedPreferences handle, so
  /// without this the first test's (empty) prefs are reused by every later one
  /// and their saved settings are silently ignored.
  void withSaved(Map<String, Object> saved) {
    SharedPreferences.setMockInitialValues(saved);
    CleanIpStore.instance.resetForTests();
  }

  setUp(() => withSaved(<String, Object>{}));

  test('re-addressing the free list is on by default', () async {
    // Leaving the published addresses in place is not the neutral choice, it is
    // the one that stops working.
    expect(CleanIpStore.kBoostFreeListByDefault, isTrue);
    final CleanIpStore store = CleanIpStore.instance;
    await store.load();
    expect(store.boostFreeList, isTrue,
        reason: 'a fresh install must be protected without being asked');
  });

  test('a user who turned it OFF keeps it off across the default change', () async {
    withSaved(<String, Object>{'nova.cleanip.boost': false});
    final CleanIpStore store = CleanIpStore.instance;
    await store.load();
    expect(store.boostFreeList, isFalse,
        reason: 'an explicit choice must survive a change of default');
  });

  test('a user who turned it ON keeps it on if the default is pulled back', () async {
    withSaved(<String, Object>{'nova.cleanip.boost': true});
    final CleanIpStore store = CleanIpStore.instance;
    await store.load();
    expect(store.boostFreeList, isTrue);
  });

  test('the pool the re-addressing reads holds more than one address', () async {
    // The background finder used to store only the single best address, so
    // freshPool stayed empty and the spread had nothing to spread. A spread of
    // one is also not a spread: it would give every user the same address and
    // recreate exactly the shared-address problem this defends against.
    final CleanIpStore store = CleanIpStore.instance;
    await store.load();
    final int now = DateTime.now().millisecondsSinceEpoch;
    await store.recordPool(<CleanIp>[
      CleanIp(ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: now),
      CleanIp(ip: '104.16.4.104', port: 443, latencyMs: 95, foundAtMs: now),
      CleanIp(ip: '172.64.0.1', port: 443, latencyMs: 120, foundAtMs: now),
    ]);
    expect(store.freshPool.length, greaterThan(1),
        reason: 'a spread of one address is the problem, not the fix');
    // Best first, so the spread draws from genuinely fast addresses.
    expect(store.freshPool.first.latencyMs, 90);
  });

  test('addresses that have aged out are not dialled', () async {
    final CleanIpStore store = CleanIpStore.instance;
    await store.load();
    final int stale = DateTime.now().millisecondsSinceEpoch -
        CleanIpStore.maxAge.inMilliseconds - 1000;
    await store.recordPool(<CleanIp>[
      CleanIp(ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: stale),
    ]);
    expect(store.freshPool, isEmpty,
        reason: 'the network under the phone changes; old finds are not trusted');
  });

  /// The pool being filled is only half the job. The connect path read the
  /// single stored address and nothing else, so the pool a scan keeps was
  /// written by the finder and then read by nothing but the free-list screen.
  /// A user who never tapped refresh dialled published addresses every session.
  group('the connect path re-addresses without being asked', () {
    ProxyNode node(String host) => ProxyNode(
          protocol: NodeProtocol.vless,
          server: host,
          port: 443,
          tls: true,
        );

    final List<ProxyNode> nodes = <ProxyNode>[
      for (int i = 0; i < 12; i++) node('n$i.example.com'),
    ];

    setUp(() {
      // Settled fact, so the rewriting is exercised without a DNS lookup and
      // the test says the same thing on a plane as on a desk.
      CleanIpFronting.forgetLookups();
      CleanIpFronting.rememberLookupsForTests(<String, bool>{
        for (final ProxyNode n in nodes) n.server: true,
      });
    });

    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<CleanIp> pool = <CleanIp>[
      CleanIp(ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: now),
      CleanIp(ip: '104.16.4.104', port: 443, latencyMs: 95, foundAtMs: now),
      CleanIp(ip: '172.64.0.1', port: 443, latencyMs: 120, foundAtMs: now),
    ];

    test('spreads across the pool rather than dialling one address', () async {
      final List<ProxyNode> out = await CleanIpFronting.applyAvailable(
        nodes,
        pool: pool,
        single: pool.first,
        seed: 1,
      );
      final Set<String> dialled = <String>{for (final ProxyNode n in out) n.server};
      expect(dialled.length, greaterThan(1),
          reason: 'one address for a whole list is one thing for a filter to '
              'notice, and one thing to lose');
      expect(dialled.every((String s) => InternetAddress.tryParse(s) != null), isTrue,
          reason: 'every fronted node must dial an address, not the published name');
      // The published name has to survive as the TLS name or the server rejects
      // the handshake it is handed.
      expect(out.first.sni, 'n0.example.com');
    });

    test('falls back to the single address when no pool was kept', () async {
      // Someone who scanned before the pool was ever filled still has one
      // stored address, and must not lose fronting because of it.
      final List<ProxyNode> out = await CleanIpFronting.applyAvailable(
        nodes,
        pool: const <CleanIp>[],
        single: pool.first,
      );
      expect(<String>{for (final ProxyNode n in out) n.server}, <String>{'104.16.4.103'});
    });

    test('leaves the list alone when no scan has found anything', () async {
      final List<ProxyNode> out = await CleanIpFronting.applyAvailable(
        nodes,
        pool: const <CleanIp>[],
        single: null,
      );
      expect(<String>{for (final ProxyNode n in out) n.server},
          <String>{for (final ProxyNode n in nodes) n.server},
          reason: 'guessing an address is how a working config gets broken');
    });

    /// Wiring, not logic, and deliberately so.
    ///
    /// The bug this whole branch exists to fix was not a wrong function, it was
    /// a right function nobody called: the screen's re-addressing had exactly
    /// one caller, the refresh button. Every test above passes just as happily
    /// with the connect path reverted to the single-address [CleanIpFronting.apply],
    /// which is the failure that already happened once. So the call itself is
    /// asserted, at the only place it can be: the source.
    test('both connect paths actually call it', () {
      for (final String path in <String>[
        'lib/src/core/proxy/singbox_proxy_controller.dart',
        'lib/src/core/proxy/desktop_proxy_controller.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src.contains('CleanIpFronting.applyAvailable('), isTrue,
            reason: '$path must front through the pool, not one address');
        expect(src.contains('return CleanIpFronting.apply(nodes, ip);'), isFalse,
            reason: '$path still takes the single-address road');
      }
    });
  });
}
