import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// A vmess:// link in the v2rayN base64-JSON shape the Nova node panel emits.
String _vmess(Map<String, dynamic> extra) {
  final Map<String, dynamic> j = <String, dynamic>{
    'v': '2',
    'ps': 'Nova vmess',
    'add': '203.0.113.7',
    'port': '443',
    'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
    'aid': '0',
    'scy': 'auto',
    'net': 'ws',
    'host': 'example.com',
    'path': '/nova',
    'tls': 'tls',
    'sni': 'example.com',
    ...extra,
  };
  return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
}

Map<String, dynamic> _endpoint(ProxyNode n) =>
    (SingboxConfig.buildMap(n)['endpoints'] as List<dynamic>).first
        as Map<String, dynamic>;

void main() {
  group('allowInsecure is honoured for every spelling', () {
    test('vmess carries the flag from the JSON body', () {
      // The regression this covers: the node panel writes allowInsecure into the
      // vmess JSON for a self-signed node, and the parser used to ignore it, so
      // vmess was the one protocol that could not reach a no-domain node.
      final ProxyNode? n = parseShareLink(_vmess(<String, dynamic>{
        'allowInsecure': '1',
      }));
      expect(n, isNotNull);
      expect(n!.protocol, NodeProtocol.vmess);
      expect(n.allowInsecure, isTrue);
      final Map<String, dynamic> tls =
          (SingboxConfig.buildMap(n)['outbounds'] as List<dynamic>)
              .firstWhere((dynamic o) => o['tag'] == 'proxy')['tls']
                  as Map<String, dynamic>;
      expect(tls['insecure'], isTrue);
    });

    test('vmess without the flag stays strict', () {
      final ProxyNode? n = parseShareLink(_vmess(<String, dynamic>{}));
      expect(n!.allowInsecure, isFalse);
    });

    test('vless accepts insecure=1, allowInsecure=true and allow_insecure=1', () {
      const String base =
          'vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.7:443'
          '?encryption=none&type=ws&security=tls&path=%2Fnova&sni=example.com';
      for (final String q in <String>[
        'insecure=1',
        'allowInsecure=true',
        'allow_insecure=1',
        'allowInsecure=1',
      ]) {
        final ProxyNode? n = parseShareLink('$base&$q#N');
        expect(n, isNotNull, reason: q);
        expect(n!.allowInsecure, isTrue, reason: q);
      }
    });

    test('trojan and hysteria2 and tuic share the same handling', () {
      expect(
        parseShareLink('trojan://pw@203.0.113.7:443'
                '?type=ws&security=tls&allow_insecure=1#T')!
            .allowInsecure,
        isTrue,
      );
      expect(
        parseShareLink('hysteria2://pw@203.0.113.7:2090'
                '?sni=example.com&allowInsecure=true#H')!
            .allowInsecure,
        isTrue,
      );
      expect(
        parseShareLink('tuic://uuid:pw@203.0.113.7:2443'
                '?sni=example.com&insecure=1#U')!
            .allowInsecure,
        isTrue,
      );
    });

    test('a strict link is still strict', () {
      final ProxyNode? n = parseShareLink(
          'vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.7:443'
          '?encryption=none&type=ws&security=tls&sni=example.com#N');
      expect(n!.allowInsecure, isFalse);
    });
  });

  group('wireguard:// links', () {
    // Exactly the shape the node agent emits: the private key is
    // percent-encoded because a raw '/' would break the URI authority.
    const String key = '2KYL5T3gG734Gc/bTlv31krekZ5K8Q2yJQlmDmKN+Vo=';
    const String serverPub = 'kO8kSQ4YsWkVpVLLJKmRlmTBWLLFdRZmRz1s6BOTnnM=';

    test('a plain link becomes a stock wireguard endpoint', () {
      final String link = 'wireguard://${Uri.encodeComponent(key)}'
          '@203.0.113.7:51822'
          '?publickey=${Uri.encodeComponent(serverPub)}'
          '&address=10.7.0.2%2F32&mtu=1420#Nova WG';
      final ProxyNode? n = parseShareLink(link);
      expect(n, isNotNull);
      expect(n!.protocol, NodeProtocol.awg);
      expect(n.server, '203.0.113.7');
      expect(n.port, 51822);
      expect(n.tag, 'Nova WG');
      final Map<String, dynamic> e = _endpoint(n);
      // No junk params, so this must be the endpoint type every shipped core
      // can already run, not the AmneziaWG one.
      expect(e['type'], 'wireguard');
      expect(e['private_key'], key);
      expect(e['mtu'], 1420);
      final Map<String, dynamic> peer =
          (e['peers'] as List<dynamic>).first as Map<String, dynamic>;
      expect(peer['public_key'], serverPub);
      expect(peer['address'], '203.0.113.7');
      expect(peer['port'], 51822);
    });

    test('junk params promote it to an awg endpoint', () {
      final String link = 'awg://${Uri.encodeComponent(key)}'
          '@203.0.113.7:51820'
          '?publickey=${Uri.encodeComponent(serverPub)}'
          '&address=10.13.13.3%2F32&jc=4&jmin=40&jmax=70&h1=677389858'
          '&h2=1150488281&h3=718829454&h4=1896311101#AWG';
      final ProxyNode? n = parseShareLink(link);
      expect(n!.protocol, NodeProtocol.awg);
      final Map<String, dynamic> e = _endpoint(n);
      expect(e['type'], 'awg');
      expect(e['jc'], 4);
      expect(e['jmin'], 40);
      expect(e['jmax'], 70);
      expect(e['h1'], '677389858');
    });

    test('underscored and dashed param spellings are accepted', () {
      final String link = 'wireguard://${Uri.encodeComponent(key)}'
          '@203.0.113.7:51820'
          '?public_key=${Uri.encodeComponent(serverPub)}&address=10.7.0.2%2F32#W';
      expect(parseShareLink(link), isNotNull);
    });

    test('a link with no peer public key is rejected, not half-built', () {
      final String link =
          'wireguard://${Uri.encodeComponent(key)}@203.0.113.7:51820#W';
      expect(parseShareLink(link), isNull);
    });

    group('no INI injection through the synthesized .conf', () {
      String linkWith(String extra) =>
          'wireguard://${Uri.encodeComponent(key)}@203.0.113.7:51820'
          '?publickey=${Uri.encodeComponent(serverPub)}'
          '&address=10.7.0.2%2F32$extra#W';

      test('a newline in a param cannot override the peer endpoint', () {
        // %0A would end the PersistentKeepalive line and start an Endpoint one,
        // which parseConf takes last-wins, silently redirecting the tunnel.
        final ProxyNode? n = parseShareLink(linkWith(
            '&keepalive=25%0AEndpoint%20%3D%20evil.example.net%3A9999'));
        // The tainted param is dropped, so the rest of the link still yields a
        // usable node; what must never happen is the endpoint moving to the
        // injected host.
        expect(n, isNotNull);
        expect(n!.server, '203.0.113.7');
        final Map<String, dynamic> peer =
            (_endpoint(n)['peers'] as List<dynamic>).first
                as Map<String, dynamic>;
        expect(peer['address'], '203.0.113.7');
        expect(peer['port'], 51820);
      });

      test('an injected [Peer] section cannot replace the real one', () {
        final ProxyNode? n = parseShareLink(linkWith(
            '&keepalive=25%0A%5BPeer%5D%0APublicKey%20%3D%20EVILKEY%3D'
            '%0AEndpoint%20%3D%20evil.example.net%3A9999'));
        if (n != null) {
          final Map<String, dynamic> peer =
              (_endpoint(n)['peers'] as List<dynamic>).first
                  as Map<String, dynamic>;
          expect(peer['public_key'], serverPub);
          expect(peer['address'], '203.0.113.7');
        }
      });

      test('a newline cannot flip a plain wireguard node into awg', () {
        final ProxyNode? n =
            parseShareLink(linkWith('&mtu=1420%0AJc%20%3D%205'));
        if (n != null) expect(_endpoint(n)['type'], 'wireguard');
      });

      test('a control character in the private key is rejected outright', () {
        final String link = 'wireguard://${Uri.encodeComponent(key)}%0AJc%20%3D%207'
            '@203.0.113.7:51820'
            '?publickey=${Uri.encodeComponent(serverPub)}&address=10.7.0.2%2F32#W';
        expect(parseShareLink(link), isNull);
      });
    });
  });

  group('xhttp cannot be silently mis-built as tcp', () {
    ProxyNode xhttpNode() => parseShareLink(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.7:443'
        '?encryption=none&type=xhttp&security=tls&path=%2Fnova'
        '&sni=example.com#X')!;

    test('the transport is recognised and tagged', () {
      expect(xhttpNode().network, 'xhttp');
    });

    test('a single pinned xhttp node fails with an actionable message', () {
      expect(
        () => SingboxConfig.buildMap(xhttpNode()),
        throwsA(isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('xhttp'),
        )),
      );
    });

    test('an all-xhttp subscription fails instead of building dead exits', () {
      expect(
        () => SingboxConfig.buildMultiMap(<ProxyNode>[xhttpNode(), xhttpNode()]),
        throwsA(isA<FormatException>()),
      );
    });

    test('xhttp nodes are dropped from a mixed pool, which still builds', () {
      final ProxyNode ok = parseShareLink(
          'vless://b831381d-6324-4d53-ad4f-8cda48b30811@198.51.100.9:443'
          '?encryption=none&type=ws&security=tls&path=%2Fa&sni=example.com#A')!;
      final ProxyNode ok2 = parseShareLink(
          'trojan://pw@198.51.100.10:443?type=ws&security=tls&path=%2Fb#B')!;
      final Map<String, dynamic> cfg =
          SingboxConfig.buildMultiMap(<ProxyNode>[xhttpNode(), ok, ok2]);
      final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
      final List<String> servers = outs
          .where((dynamic o) => o['server'] != null)
          .map((dynamic o) => o['server'] as String)
          .toList();
      expect(servers, containsAll(<String>['198.51.100.9', '198.51.100.10']));
      expect(servers, isNot(contains('203.0.113.7')));
    });
  });
}
