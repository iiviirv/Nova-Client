import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link_builder.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The exact pair a tester reported from a restricted network: the standard
/// Nova link that did not connect, and the cf-optimizor (PattNG) rewrite of it
/// that did. Only the credential differs from what they sent.
const String kNovaLink =
    'vless://00000000-0000-4000-8000-000000000000@172.67.70.215:2053'
    '?encryption=none&security=tls&sni=azure-fox-f311.altramax083.workers.dev'
    '&fp=chrome&insecure=0&allowInsecure=0&type=ws'
    '&host=azure-fox-f311.altramax083.workers.dev'
    '&path=%2Fde1d8f8364d4%2Fproxyip%3D93.115.23.184#Nova';

const String kPattLink =
    'vless://00000000-0000-4000-8000-000000000000@172.67.70.215:2053'
    '?cs=TLS_AES_256_GCM_SHA384%3ATLS_CHACHA20_POLY1305_SHA256%3ATLS_AES_128_GCM_SHA256'
    '%3ATLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384%3ATLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384'
    '%3ATLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256%3ATLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'
    '%3ATLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256%3ATLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256'
    '%3ATLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA%3ATLS_ECDHE_RSA_WITH_AES_256_CBC_SHA'
    '%3ATLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256%3ATLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256'
    '&path=%2Fde1d8f8364d4%2Fproxyip%3D93.115.23.184&security=tls&encryption=none'
    '&fm=%7B%22tcp%22%3A%5B%7B%22type%22%3A%22fragment%22%2C%22settings%22%3A%7B%22packets%22%3A%22tlshello%22%2C%22lengths%22%3A%5B%225%22%2C%2294%22%2C%221%22%5D%2C%22delays%22%3A%5B%220%22%5D%2C%22maxSplit%22%3A%220%22%7D%7D%2C%7B%22type%22%3A%22fragment%22%2C%22settings%22%3A%7B%22packets%22%3A%221-1%22%2C%22lengths%22%3A%5B%22109%22%2C%221%22%5D%2C%22delays%22%3A%5B%221%22%5D%2C%22maxSplit%22%3A%22355%22%7D%7D%5D%7D'
    '&insecure=0&host=azure-fox-f311.altramax083.workers.dev&fp=unsafe&type=ws'
    '&sni=azure-fox-f311.altramax083.workers.dev&allowInsecure=0#Nova';

Map<String, dynamic> _tlsOf(Map<String, dynamic> cfg) {
  final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
  final Map<String, dynamic> o = outs.firstWhere(
      (dynamic e) => (e as Map<String, dynamic>)['type'] == 'vless') as Map<String, dynamic>;
  return o['tls'] as Map<String, dynamic>;
}

void main() {
  group('reading the PattNG profile from a link', () {
    test('the standard Nova link is a clean-IP fronted node, not hardened', () {
      final ProxyNode n = parseShareLink(kNovaLink)!;
      expect(n.isCleanIpFronted, isTrue,
          reason: 'IP address with a workers.dev SNI is the case this is for');
      expect(n.isHardenedTls, isFalse);
      expect(n.fingerprint, 'chrome');
    });

    test('the cf-optimizor link carries all three signals', () {
      final ProxyNode n = parseShareLink(kPattLink)!;
      expect(n.isHardenedTls, isTrue);
      expect(n.fingerprint, 'unsafe');
      expect(n.cipherSuites.length, 13);
      expect(n.cipherSuites.first, 'TLS_AES_256_GCM_SHA384');
      expect(n.cipherSuites.last, 'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256');
      final Map<String, dynamic> fm =
          jsonDecode(n.fragmentMask!) as Map<String, dynamic>;
      final List<dynamic> tcp = fm['tcp'] as List<dynamic>;
      expect(tcp.length, 2, reason: 'two fragment stages');
      expect((tcp[0] as Map)['settings']['packets'], 'tlshello');
      expect((tcp[1] as Map)['settings']['packets'], '1-1');
    });

    test('a domain-addressed node is never treated as clean-IP fronted', () {
      final ProxyNode n = parseShareLink(
        'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
        '?security=tls&type=ws&sni=node.example.com#D',
      )!;
      expect(n.isCleanIpFronted, isFalse);
    });
  });

  group('the bypass profile in the config', () {
    test('a link that asks for it gets Go TLS, its ciphers, and the exact mask',
        () {
      final Map<String, dynamic> tls =
          _tlsOf(SingboxConfig.buildMap(parseShareLink(kPattLink)!));
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse,
          reason: 'fp=unsafe means no browser fingerprint');
      // Exact fragmentation: the link's own fm mask, verbatim.
      final List<dynamic> nf = tls['nova_fragment'] as List<dynamic>;
      expect(nf.length, 2);
      expect((nf[0] as Map)['packets'], 'tlshello');
      expect((nf[0] as Map)['lengths'], <String>['5', '94', '1']);
      expect((nf[1] as Map)['packets'], '1-1');
      expect((nf[1] as Map)['lengths'], <String>['109', '1']);
      expect((nf[1] as Map)['maxSplit'], '355');
      final List<dynamic> cs = tls['cipher_suites'] as List<dynamic>;
      // The two CBC_SHA256 suites are in Go's insecure list; the core refuses
      // the whole outbound over them, so they are dropped, and the order of the
      // rest is kept as the recipe gives it.
      expect(cs.length, 11);
      expect(cs, isNot(contains('TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256')));
      expect(cs, isNot(contains('TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256')));
      expect(cs.first, 'TLS_AES_256_GCM_SHA384');
      expect(cs.last, 'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA');
    });

    test('a standard link is untouched by default', () {
      final Map<String, dynamic> tls =
          _tlsOf(SingboxConfig.buildMap(parseShareLink(kNovaLink)!));
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isTrue);
      expect((tls['utls'] as Map<String, dynamic>)['fingerprint'], 'chrome');
      expect(tls.containsKey('cipher_suites'), isFalse);
      expect(tls.containsKey('nova_fragment'), isFalse);
    });

    test('hardenTls applies the default mask to a clean-IP fronted node', () {
      final Map<String, dynamic> tls = _tlsOf(SingboxConfig.buildMap(
        parseShareLink(kNovaLink)!,
        options: const SingboxRouteOptions(hardenTls: true),
      ));
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse);
      // No fm on the standard link, so the field-tested default mask is used.
      final List<dynamic> nf = tls['nova_fragment'] as List<dynamic>;
      expect(nf.length, 2);
      expect((nf[0] as Map)['lengths'], <String>['5', '94', '1']);
      expect((tls['cipher_suites'] as List<dynamic>).length, 11);
    });

    test('Windows keeps only the TLS-record stage of the mask', () {
      // The TCP-segment stage needs an ACK-wait an unelevated Windows core
      // cannot drive, so only the tlshello record split survives there.
      final Map<String, dynamic> tls = _tlsOf(SingboxConfig.buildMap(
        parseShareLink(kPattLink)!,
        options:
            const SingboxRouteOptions(hardenPacketFragment: false),
      ));
      final List<dynamic> nf = tls['nova_fragment'] as List<dynamic>;
      expect(nf.length, 1);
      expect((nf[0] as Map)['packets'], 'tlshello');
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse);
    });

    test('hardenTls leaves a domain-addressed node alone', () {
      final ProxyNode domain = parseShareLink(
        'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
        '?security=tls&type=ws&sni=node.example.com#D',
      )!;
      final Map<String, dynamic> tls = _tlsOf(SingboxConfig.buildMap(
        domain,
        options: const SingboxRouteOptions(hardenTls: true),
      ));
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isTrue);
      expect(tls.containsKey('cipher_suites'), isFalse);
    });

    test('hardenTls applies inside the auto pool too', () {
      final List<ProxyNode> nodes = <ProxyNode>[
        parseShareLink(kNovaLink)!,
        parseShareLink(kNovaLink.replaceFirst('172.67.70.215', '104.16.1.1'))!,
      ];
      final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(
        nodes,
        options: const SingboxRouteOptions(hardenTls: true),
      );
      final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
      final Iterable<Map<String, dynamic>> vless = outs
          .cast<Map<String, dynamic>>()
          .where((Map<String, dynamic> o) => o['type'] == 'vless');
      expect(vless.length, 2);
      for (final Map<String, dynamic> o in vless) {
        expect(((o['tls'] as Map)['utls'] as Map)['enabled'], isFalse);
      }
    });

    test('bypass editor overrides feed the config (custom mask + ciphers)', () {
      // A user-edited finalmask and cipher list from the bypass editor must
      // reach the emitted config, so re-tuning the recipe actually changes what
      // the core sends.
      const String customMask =
          '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
          '"lengths":["3","7"],"delays":["0"],"maxSplit":"0"}}]}';
      final Map<String, dynamic> tls = _tlsOf(SingboxConfig.buildMap(
        parseShareLink(kNovaLink)!,
        options: const SingboxRouteOptions(
          hardenTls: true,
          bypassFragmentMask: customMask,
          bypassCipherSuites: <String>['TLS_AES_128_GCM_SHA256'],
        ),
      ));
      final List<dynamic> nf = tls['nova_fragment'] as List<dynamic>;
      expect(nf.length, 1, reason: 'the custom single-stage mask is used');
      expect((nf[0] as Map)['lengths'], <String>['3', '7']);
      expect(tls['cipher_suites'], <String>['TLS_AES_128_GCM_SHA256']);
    });

    test('a carrier fingerprint override does not undo an explicit unsafe', () {
      final Map<String, dynamic> tls = _tlsOf(SingboxConfig.buildMap(
        parseShareLink(kPattLink)!,
        options: const SingboxRouteOptions(fingerprintOverride: 'firefox'),
      ));
      expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse);
    });
  });

  group('sharing', () {
    test('a hardened node re-shares in the PattNG shape and parses back equal',
        () {
      final ProxyNode hardened = parseShareLink(kNovaLink)!.hardened();
      final String link = buildShareLink(hardened);
      expect(link, contains('fp=unsafe'));
      expect(link, contains('cs='));
      expect(link, contains('fm='));
      final ProxyNode back = parseShareLink(link)!;
      expect(back.fingerprint, 'unsafe');
      expect(back.cipherSuites, kBypassCipherSuites);
      expect(jsonDecode(back.fragmentMask!), jsonDecode(kBypassFragmentMask));
      expect(back.server, hardened.server);
      expect(back.wsPath, hardened.wsPath);
    });

    test('hardened() is idempotent and keeps a link\'s own profile', () {
      final ProxyNode own = parseShareLink(kPattLink)!;
      expect(own.hardened().cipherSuites.length, 13,
          reason: 'a link with its own ciphers keeps them');
      final ProxyNode h = parseShareLink(kNovaLink)!.hardened();
      expect(h.hardened().cipherSuites, h.cipherSuites);
    });
  });
}
