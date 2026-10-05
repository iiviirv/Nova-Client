import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/ech_key.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Shipping Cloudflare's ECH key as a constant broke every ECH config in the
/// field. A tester had it working for about two hours, then nothing connected
/// at all, on filtered and unfiltered networks alike, while another client kept
/// working because it reads the key from DNS on each connection. The log said
/// it outright: "certificate is valid for cloudflare-ech.com, not `the host`",
/// which is what a server returns when it cannot decrypt the inner hello.
///
/// A stale key does not degrade. It fails every connection on the profile, so
/// the key is now fetched and the constant is only a floor.
void main() {
  setUp(EchKey.invalidate);

  group('reading the answer', () {
    const String answer = '''
{"Status":0,"Answer":[{"name":"cloudflare-ech.com","type":65,
"data":"1 . alpn=h3,h2 ipv4hint=104.18.10.118 ech=AEX+DQBBogAgACAW ipv6hint=2606:4700::6812:a76"}]}''';

    test('the ech value is picked out of the record', () {
      expect(EchKey.parseEch(answer), 'AEX+DQBBogAgACAW');
    });

    test('an answer without one is not mistaken for a key', () {
      expect(EchKey.parseEch('{"Status":0,"Answer":[{"type":65,"data":"1 . alpn=h3"}]}'),
          isNull);
      expect(EchKey.parseEch('{"Status":3}'), isNull);
      expect(EchKey.parseEch('not json at all'), isNull);
      expect(EchKey.parseEch(''), isNull);
    });
  });

  group('which key a config gets', () {
    test('a fetched key is preferred over the built-in one', () async {
      final String? got = await EchKey.current(fetch: () async => 'FRESH==');
      expect(got, 'FRESH==');
      expect(got, isNot(kCloudflareEchConfig));
    });

    test('a failed fetch returns nothing rather than a guess', () async {
      expect(await EchKey.current(fetch: () async => null), isNull,
          reason: 'this is the whole bug: returning the built-in key here is '
              'what left a tester unable to connect on a brand new phone, '
              'because Cloudflare had rotated and a stale key is refused by '
              'every server rather than merely being less private');
    });

    test('the built-in key is never handed out as an answer', () async {
      expect(await EchKey.current(fetch: () async => null),
          isNot(kCloudflareEchConfig));
    });

    test('a fetched key is reused rather than looked up every connection',
        () async {
      await EchKey.current(fetch: () async => 'FIRST==');
      int calls = 0;
      final String? got = await EchKey.current(fetch: () async {
        calls++;
        return 'SECOND==';
      });
      expect(got, 'FIRST==');
      expect(calls, 0, reason: 'a lookup per connection is a lookup too many');
    });

    test('a key older than its life is looked up again', () async {
      await EchKey.current(fetch: () async => 'OLD==');
      final String? got = await EchKey.current(
          now: DateTime.now().add(EchKey.maxAge * 2),
          fetch: () async => 'NEW==');
      expect(got, 'NEW==',
          reason: 'this is the rotation that broke every config in the field');
    });
  });

  group('what the config ends up carrying', () {
    ProxyNode node({String? reality}) => ProxyNode(
          protocol: NodeProtocol.vless,
          server: '104.16.0.1',
          port: 443,
          uuid: '00000000-0000-0000-0000-000000000000',
          tls: true,
          sni: 'example.com',
          network: 'ws',
          wsPath: '/ws',
          realityPublicKey: reality,
          tag: 'n',
        );

    Map<String, dynamic> tlsOf(ProxyNode n, SingboxRouteOptions o) {
      final Map<String, dynamic> m = SingboxConfig.buildMap(n, options: o);
      final List<dynamic> outs = m['outbounds'] as List<dynamic>;
      return (outs.first as Map<String, dynamic>)['tls']
          as Map<String, dynamic>;
    }

    test('ECH is never asked for alongside Reality', () {
      final Map<String, dynamic> tls = tlsOf(
          node(reality: 'Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMDA'),
          const SingboxRouteOptions(ech: true));
      expect(tls.containsKey('ech'), isFalse,
          reason: 'Reality brings its own handshake; asking for both made the '
              'core reject the outbound, which a tester saw as the lightning '
              'test failing on any list holding one Reality node');
      expect(tls['reality'], isNotNull);
    });

    test('a non-Reality node still gets it', () {
      expect(tlsOf(node(), const SingboxRouteOptions(ech: true))['ech'],
          isNotNull);
    });
  });

  group('the two bypasses cannot both be on', () {
    test('the free list ships with ECH, not the fragmenting bypass', () {
      final ProxyProfile free = buildFreeProfile();
      expect(free.echSni, isTrue);
      expect(free.hardenTls, isFalse,
          reason: 'fragmentation is blocked on the network the free list is '
              'most used on, and the two are mutually exclusive');
    });
  });

  group('a spec the user edited', () {
    test('changing where to look drops what was fetched from elsewhere',
        () async {
      const EchSpec a = EchSpec(domain: 'a.com', resolver: 'udp://1.1.1.1');
      const EchSpec b = EchSpec(domain: 'b.com', resolver: 'udp://1.1.1.1');
      expect(await EchKey.current(spec: a, fetch: () async => 'FROM_A=='),
          'FROM_A==');
      int calls = 0;
      final String? got = await EchKey.current(
          spec: b,
          fetch: () async {
            calls++;
            return 'FROM_B==';
          });
      expect(got, 'FROM_B==');
      expect(calls, 1,
          reason: 'serving a key fetched from somewhere the user no longer '
              'asked about is how a setting silently does nothing');
    });

    test('a failed fetch for a new spec does not serve the old answer',
        () async {
      const EchSpec a = EchSpec(domain: 'a.com', resolver: 'udp://1.1.1.1');
      const EchSpec b = EchSpec(domain: 'b.com', resolver: 'udp://1.1.1.1');
      await EchKey.current(spec: a, fetch: () async => 'FROM_A==');
      expect(await EchKey.current(spec: b, fetch: () async => null), isNull,
          reason: 'another lookup\'s answer is not this lookup\'s answer');
    });

    test('the same spec is still reused', () async {
      const EchSpec a = EchSpec(domain: 'a.com', resolver: 'udp://1.1.1.1');
      await EchKey.current(spec: a, fetch: () async => 'ONCE==');
      int calls = 0;
      expect(
          await EchKey.current(
              spec: a,
              fetch: () async {
                calls++;
                return 'AGAIN==';
              }),
          'ONCE==');
      expect(calls, 0);
    });
  });

  group('when no key can be had', () {
    test('a cached key for the same lookup is still used', () async {
      const EchSpec a = EchSpec(domain: 'a.com', resolver: 'udp://1.1.1.1');
      await EchKey.current(spec: a, fetch: () async => 'REAL==');
      // Age it past its life so the next call tries to refetch and fails.
      expect(
          await EchKey.current(
              spec: a,
              now: DateTime.now().add(EchKey.maxAge * 2),
              fetch: () async => null),
          'REAL==',
          reason: 'it was real when it was fetched, and Cloudflare keeps old '
              'keys working for a while; the built-in one is older than '
              'anything');
    });

    test('more than one resolver is tried before giving up', () {
      expect(EchKey.kResolvers.length, greaterThan(1),
          reason: 'one endpoint not answering is exactly what happened; '
              'different networks block different things');
      expect(EchKey.kResolvers.where((String r) => r.startsWith('https://')),
          isNotEmpty);
      expect(EchKey.kResolvers.where((String r) => r.startsWith('udp://')),
          isNotEmpty,
          reason: 'a network that blocks DoH may still answer plain DNS');
    });
  });

  group('topping the key up while something works', () {
    test('a tunnel refresh replaces what is remembered', () async {
      const EchSpec a = EchSpec(domain: 'a.com', resolver: 'udp://1.1.1.1');
      await EchKey.current(spec: a, fetch: () async => 'OLD==');
      await EchKey.refreshThroughTunnel(a);
      // Nothing to assert about the value without a network; what matters is
      // that the call is safe and leaves a usable key behind rather than
      // clearing one.
      expect(await EchKey.current(spec: a, fetch: () async => null), isNotNull,
          reason: 'a refresh that fails must not destroy the key already held');
    });

    test('the resolver list covers more than the two obvious addresses', () {
      final String joined = EchKey.kResolvers.join(' ');
      expect(EchKey.kResolvers.length, greaterThanOrEqualTo(4));
      expect(joined.contains('quad9') || joined.contains('opendns'), isTrue,
          reason: '1.1.1.1 and 8.8.8.8 are the two most likely to be blocked '
              'outright, precisely because everyone uses them');
    });
  });
}
