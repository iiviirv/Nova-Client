import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

void main() {
  group('parseShareLink — VLESS', () {
    test('parses a VLESS WS+TLS link', () {
      final node = parseShareLink(
        'vless://b9c40223-bbc5-4311-89d3-f1ed54bbca86@nova.example.com:443'
        '?encryption=none&security=tls&sni=cdn.example.com&type=ws'
        '&path=%2Fnova&host=cdn.example.com&fp=chrome#Nova%20Node',
      );
      expect(node, isNotNull);
      expect(node!.protocol, NodeProtocol.vless);
      expect(node.server, 'nova.example.com');
      expect(node.port, 443);
      expect(node.uuid, 'b9c40223-bbc5-4311-89d3-f1ed54bbca86');
      expect(node.tls, isTrue);
      expect(node.sni, 'cdn.example.com');
      expect(node.network, 'ws');
      expect(node.wsPath, '/nova');
      expect(node.wsHost, 'cdn.example.com');
      expect(node.fingerprint, 'chrome');
      expect(node.tag, 'Nova Node');
    });
  });

  group('parseShareLink — Trojan', () {
    test('parses a Trojan WS+TLS link', () {
      final node = parseShareLink(
        'trojan://secretpass@tr.example.com:443?security=tls&type=ws&path=/t#TR',
      );
      expect(node, isNotNull);
      expect(node!.protocol, NodeProtocol.trojan);
      expect(node.password, 'secretpass');
      expect(node.server, 'tr.example.com');
      expect(node.port, 443);
      expect(node.tls, isTrue);
      expect(node.network, 'ws');
      expect(node.wsPath, '/t');
    });
  });

  group('parseShareLink — Shadowsocks', () {
    test('parses a SIP002 ss link', () {
      final node = parseShareLink(
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@ss.example.com:8388#SS',
      );
      expect(node, isNotNull);
      expect(node!.protocol, NodeProtocol.shadowsocks);
      expect(node.method, 'aes-256-gcm');
      expect(node.password, 'password');
      expect(node.server, 'ss.example.com');
      expect(node.port, 8388);
    });

    test('parses url-safe base64 without padding', () {
      final node = parseShareLink(
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@ss.example.com:8388#SS',
      );
      expect(node, isNotNull);
      expect(node!.method, 'aes-256-gcm');
      expect(node.password, 'password');
    });
  });

  group('parseShareLink — invalid', () {
    test('returns null for unsupported / malformed input', () {
      expect(parseShareLink(''), isNull);
      expect(parseShareLink('https://example.com'), isNull);
      expect(parseShareLink('vless://'), isNull);
      expect(parseShareLink('not a link'), isNull);
    });
  });

  group('SingboxConfig.buildMap', () {
    ProxyNode vlessNode() => parseShareLink(
          'vless://b9c40223-bbc5-4311-89d3-f1ed54bbca86@nova.example.com:443'
          '?security=tls&sni=cdn.example.com&type=ws&path=%2Fnova&host=cdn.example.com#N',
        )!;

    test('produces a TUN inbound', () {
      final cfg = SingboxConfig.buildMap(vlessNode());
      final inbounds = cfg['inbounds'] as List<dynamic>;
      expect(inbounds, hasLength(1));
      expect((inbounds.first as Map)['type'], 'tun');
      expect((inbounds.first as Map)['auto_route'], isTrue);
    });

    test('builds the VLESS outbound with TLS + WS transport', () {
      final cfg = SingboxConfig.buildMap(vlessNode());
      final outbounds = (cfg['outbounds'] as List<dynamic>).cast<Map>();
      final proxy = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(proxy['type'], 'vless');
      expect(proxy['server'], 'nova.example.com');
      expect(proxy['server_port'], 443);
      expect(proxy['uuid'], 'b9c40223-bbc5-4311-89d3-f1ed54bbca86');
      expect((proxy['tls'] as Map)['server_name'], 'cdn.example.com');
      expect((proxy['transport'] as Map)['type'], 'ws');
      expect((proxy['transport'] as Map)['path'], '/nova');

      // direct/block/dns outbounds always present.
      final tags = outbounds.map((o) => o['tag']).toSet();
      expect(tags, containsAll(<String>['proxy', 'direct', 'block', 'dns-out']));
    });

    test('rule mode routes final through the proxy', () {
      final cfg = SingboxConfig.buildMap(vlessNode());
      expect((cfg['route'] as Map)['final'], 'proxy');
    });

    test('direct mode routes final through direct', () {
      final cfg = SingboxConfig.buildMap(
        vlessNode(),
        options: const SingboxRouteOptions(mode: SingboxMode.direct),
      );
      expect((cfg['route'] as Map)['final'], 'direct');
    });

    test('Iran bypass adds geoip/geosite rule-sets', () {
      final cfg = SingboxConfig.buildMap(vlessNode());
      final route = cfg['route'] as Map;
      final ruleSets = (route['rule_set'] as List).cast<Map>();
      final tags = ruleSets.map((r) => r['tag']).toSet();
      expect(tags, containsAll(<String>['geoip-ir', 'geosite-ir']));
    });

    test('build() returns valid JSON', () {
      final json = SingboxConfig.build(vlessNode());
      expect(json, contains('"type": "tun"'));
      expect(json, contains('"tag": "proxy"'));
    });
  });
}
