import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/ech_key.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Field report: with ECH on, a tester reached some Nova Proxy servers and none
/// of his own. ECH is not a general privacy switch, it is a Cloudflare feature:
/// the edge decrypts the inner name, so a server that is not behind Cloudflare
/// has nothing to decrypt it with and refuses the handshake. Nova was applying
/// it to every TLS server in the profile, so turning it on broke the user's own
/// VPS while leaving the Cloudflare-fronted ones working.
void main() {
  ProxyNode node({required String server, String? sni}) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: server,
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        sni: sni ?? 'example.com',
        network: 'ws',
        wsPath: '/ws',
        tag: 'n',
      );

  bool echOn(ProxyNode n) {
    final Map<String, dynamic> m = SingboxConfig.buildMap(n,
        options: const SingboxRouteOptions(ech: true, echConfig: 'KEY=='));
    final List<dynamic> outs = m['outbounds'] as List<dynamic>;
    final Map<String, dynamic> tls =
        (outs.first as Map<String, dynamic>)['tls'] as Map<String, dynamic>;
    return tls.containsKey('ech');
  }

  test('a Cloudflare address gets ECH', () {
    expect(echOn(node(server: '104.16.0.1')), isTrue);
    expect(echOn(node(server: '172.67.82.107')), isTrue);
  });

  test('a workers.dev host gets it even without a Cloudflare address', () {
    expect(
        echOn(node(server: 'breezy-meadow.calm-pine.workers.dev',
            sni: 'breezy-meadow.calm-pine.workers.dev')),
        isTrue);
  });

  test('the user\'s own VPS does not, because it cannot answer one', () {
    expect(echOn(node(server: '203.0.113.9')), isFalse,
        reason: 'this is the report: ECH on broke his own server while the '
            'Cloudflare-fronted ones kept working');
    expect(echOn(node(server: 'vpn.example.org', sni: 'vpn.example.org')),
        isFalse);
  });

  test('plain DNS to 1.1.1.1 is tried before DoH', () {
    // Corrected by the field, not assumed: every other client he tried does the
    // lookup as udp://1.1.1.1 and works on the same network where Nova's DoH
    // call to the same address did not. The old order came from a report about
    // UDP carrying tunnel traffic, which is not a DNS query on port 53.
    final int udp = EchKey.kResolvers.indexOf('udp://1.1.1.1');
    final int doh = EchKey.kResolvers.indexOf('https://1.1.1.1/dns-query');
    expect(udp, isNot(-1));
    expect(udp, lessThan(doh));
    expect(EchKey.kResolvers, contains('udp://1.0.0.1'),
        reason: 'the other address he named works there too');
  });
}
