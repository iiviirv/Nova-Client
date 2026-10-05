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

  test('a server behind Cloudflare on its own domain keeps ECH', () {
    // The correction that matters. A tester's own server sits behind Cloudflare
    // on its own domain, so it is addressed by name and no address check can
    // see that it is Cloudflare. An earlier version of this gate allowed only a
    // Cloudflare IP literal or a workers.dev name and would have switched ECH
    // off for exactly the server he needs it for. Measured: ctcf.mayata.sbs
    // resolves onto 104.21.24.149 and 172.67.219.67 and publishes an ECH key.
    expect(echOn(node(server: 'ctcf.mayata.sbs', sni: 'ctcf.mayata.sbs')),
        isTrue);
    expect(echOn(node(server: 'vpn.example.org', sni: 'vpn.example.org')),
        isTrue,
        reason: 'a name cannot be judged here without a lookup this code '
            'cannot afford, and refusing to try is as wrong as always trying');
  });

  test('a bare non-Cloudflare address does not, since nothing can answer it',
      () {
    expect(echOn(node(server: '203.0.113.9')), isFalse,
        reason: 'an address literal is the one case that can be judged: it is '
            'not Cloudflare, so there is no edge to decrypt the inner name');
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
