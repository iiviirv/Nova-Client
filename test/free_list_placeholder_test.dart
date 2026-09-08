import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_fronting.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_store.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

/// Publishing the free list with NO addresses at all.
///
/// The list is published at a world-readable URL, so any address in it can be
/// fetched once and blocked. Re-addressing on the device helped, but the
/// published addresses were still there to be blocked, and still shared by
/// everyone who had not scanned.
///
/// Publishing placeholders instead removes the target completely: there is
/// nothing in the file to block, and every user's copy is addressed from their
/// own scan, so the traffic spreads across as many addresses as there are
/// users. Measured in the field on two Iranian ISPs, a scan finds about 300
/// live addresses, so the pool is real.
///
/// The whole idea rests on one thing being true: a node that has NOT been given
/// an address must never be dialled. 127.0.0.1 is the user's own phone.
void main() {
  _noTrafficMemory();
  ProxyNode placeholder({
    String server = '127.0.0.1',
    String? sni = 'free.example.com',
    String? wsHost,
    int port = 443,
    bool tls = true,
  }) =>
      ProxyNode(
        protocol: NodeProtocol.vless,
        server: server,
        port: port,
        tls: tls,
        sni: sni,
        wsHost: wsHost,
        tag: 'Nova Free 001',
      );

  group('what counts as a node published without an address', () {
    test('a placeholder address with a TLS name does', () {
      expect(CleanIpFronting.needsAddress(placeholder()), isTrue);
      expect(
          CleanIpFronting.needsAddress(placeholder(server: '0.0.0.0')), isTrue);
    });

    test('a Host header alone is enough of a name', () {
      expect(
          CleanIpFronting.needsAddress(
              placeholder(sni: null, wsHost: 'free.example.com')),
          isTrue);
    });

    test("somebody's real local proxy is NOT a placeholder", () {
      // The distinguishing fact is the TLS name. A local proxy on 127.0.0.1
      // with no name attached is a real config someone wrote, and rewriting its
      // address would break it.
      expect(
          CleanIpFronting.needsAddress(placeholder(sni: null, wsHost: null)),
          isFalse,
          reason: 'without a name there is nothing to put in the handshake, so '
              'this cannot be one of ours');
    });

    test('an ordinary published server is not a placeholder', () {
      expect(
          CleanIpFronting.needsAddress(placeholder(server: 'a.example.com')),
          isFalse);
      expect(
          CleanIpFronting.needsAddress(placeholder(server: '104.16.4.103')),
          isFalse,
          reason: 'a real address is not a placeholder, however much we would '
              'prefer it were not published');
    });
  });

  group('a placeholder is eligible for an address', () {
    test('it is frontable even though its address is an IP literal', () {
      // The ordinary rule skips anything already addressed by number, because
      // that is usually a clean IP somebody chose. A placeholder is the
      // exception and had to be taught explicitly.
      expect(CleanIpFronting.couldBeFronted(placeholder()), isTrue);
    });

    test('but not on a port Cloudflare does not terminate TLS on', () {
      expect(CleanIpFronting.couldBeFronted(placeholder(port: 8080)), isFalse);
    });

    test('and not without TLS', () {
      expect(CleanIpFronting.couldBeFronted(placeholder(tls: false)), isFalse);
    });
  });

  group('an unaddressed node is never dialled', () {
    test('it is dropped when no scan has supplied an address', () {
      final List<ProxyNode> kept =
          CleanIpFronting.dropUnaddressed(<ProxyNode>[placeholder()]);
      expect(kept, isEmpty,
          reason: '127.0.0.1 is the user\'s own device, so dialling it is not '
              'a degraded connection, it is a broken one');
    });

    test('real servers alongside it are kept', () {
      final ProxyNode real = placeholder(server: 'a.example.com');
      final List<ProxyNode> kept = CleanIpFronting.dropUnaddressed(
          <ProxyNode>[placeholder(), real, placeholder(server: '0.0.0.0')]);
      expect(kept.map((ProxyNode n) => n.server), <String>['a.example.com'],
          reason: 'a partly published list still works for the part that has '
              'addresses');
    });

    test('a list with no placeholders is returned untouched', () {
      final List<ProxyNode> nodes = <ProxyNode>[
        placeholder(server: 'a.example.com'),
        placeholder(server: 'b.example.com'),
      ];
      expect(CleanIpFronting.dropUnaddressed(nodes), same(nodes));
    });
  });

  group('once addressed, the handshake still says the right name', () {
    test('the scanned address replaces the placeholder and the name survives',
        () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final List<CleanIp> pool = <CleanIp>[
        CleanIp(ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: now),
      ];
      final List<ProxyNode> out = await CleanIpFronting.applyAvailable(
        <ProxyNode>[placeholder()],
        pool: pool,
        single: pool.first,
      );
      expect(out.single.server, '104.16.4.103');
      expect(out.single.sni, 'free.example.com',
          reason: 'the published name is what the server expects to see');
      // And it is now addressed, so it survives the drop.
      expect(CleanIpFronting.dropUnaddressed(out), hasLength(1));
    });

    test('a placeholder is never used as the TLS name', () async {
      // The trap: the ordinary code fills a missing SNI from the address. For a
      // placeholder that would send "127.0.0.1" as the server name and every
      // handshake would fail.
      final int now = DateTime.now().millisecondsSinceEpoch;
      final List<CleanIp> pool = <CleanIp>[
        CleanIp(ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: now),
      ];
      final List<ProxyNode> out = await CleanIpFronting.applyAvailable(
        <ProxyNode>[placeholder(sni: null, wsHost: 'free.example.com')],
        pool: pool,
        single: pool.first,
      );
      expect(out.single.sni, isNot(anyOf('127.0.0.1', '0.0.0.0')));
      expect(out.single.sni, 'free.example.com');
    });
  });
}

/// A latency proves a server answered one probe. It does not prove the server
/// routes anything, and some do not: a tester in Iran found two of twenty-one
/// free servers that connected, showed a healthy ping, and loaded nothing.
///
/// Nova already noticed at the time and said so, but the knowledge died with
/// the session, so the list went on showing a good number beside a server known
/// not to work and the same node was picked again.
void _noTrafficMemory() {
  group('a server that carries nothing is remembered', () {
    const String key = 'node-key-1';

    test('the verdict is recorded', () {
      const CoreNodeHealth before = CoreNodeHealth(delayMsByKey: <String, int>{key: 120});
      final CoreNodeHealth after = before.withNoTraffic(key);
      expect(after.noTrafficKeys, contains(key));
    });

    test('it survives the tunnel going away', () {
      final CoreNodeHealth h = const CoreNodeHealth(
        delayMsByKey: <String, int>{key: 120},
        selectedKey: key,
      ).withNoTraffic(key);
      expect(h.withoutSelection.noTrafficKeys, contains(key),
          reason: 'forgetting on disconnect is what let the same dead exit be '
              'chosen again on the next connect');
      expect(h.withoutSelection.selectedKey, isNull);
    });

    test('a fresh latency does NOT clear it', () {
      // The trap: re-testing produces a number, and a number is exactly what
      // this server always had. Only real traffic clears the verdict.
      final CoreNodeHealth h =
          const CoreNodeHealth(delayMsByKey: <String, int>{}).withNoTraffic(key);
      expect(h.noTrafficKeys, contains(key));
    });

    test('traffic actually flowing does clear it', () {
      final CoreNodeHealth h =
          const CoreNodeHealth(delayMsByKey: <String, int>{}).withNoTraffic(key);
      expect(h.withTrafficRestored(key).noTrafficKeys, isEmpty,
          reason: 'a server unreachable on one network can be fine on the next');
    });

    test('clearing one that was never marked changes nothing', () {
      const CoreNodeHealth h = CoreNodeHealth(delayMsByKey: <String, int>{});
      expect(h.withTrafficRestored(key), same(h));
    });
  });
}
