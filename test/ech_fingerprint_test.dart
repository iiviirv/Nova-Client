import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Field log from a Samsung, build 1.30.1: every connection failed with
/// "tls: malformed outer client hello", two hundred of them in one session,
/// while the same build on another phone connected fine. The difference was one
/// line above the failures: "Carrier profile: carrier -> fingerprint
/// randomized". A randomized ClientHello is assembled from a shuffled extension
/// set and cannot carry the ECH extension in a shape a server will accept.
///
/// The recipe this feature was built from says to set the fingerprint to
/// chrome. Two of its three lines were implemented, dropping the fragment mask
/// and supplying the config list, and this one was not.
void main() {
  ProxyNode node({String? fingerprint}) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: '104.16.0.1',
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        sni: 'example.com',
        network: 'ws',
        wsPath: '/ws',
        fingerprint: fingerprint,
        tag: 'n',
      );

  String fpOf(ProxyNode n, SingboxRouteOptions o) {
    final Map<String, dynamic> m = SingboxConfig.buildMap(n, options: o);
    final List<dynamic> outs = m['outbounds'] as List<dynamic>;
    final Map<String, dynamic> tls =
        (outs.first as Map<String, dynamic>)['tls'] as Map<String, dynamic>;
    return (tls['utls'] as Map<String, dynamic>)['fingerprint'] as String;
  }

  test('ECH overrides a randomized carrier fingerprint', () {
    expect(
        fpOf(node(),
            const SingboxRouteOptions(
                ech: true, echConfig: 'K==', fingerprintOverride: 'randomized')),
        'chrome',
        reason: 'randomized plus ECH is "malformed outer client hello" on every '
            'single connection, which is how one phone worked and another '
            'could not connect at all');
  });

  test('ECH overrides a randomized fingerprint pinned by the link too', () {
    expect(
        fpOf(node(fingerprint: 'randomized'),
            const SingboxRouteOptions(ech: true, echConfig: 'K==')),
        'chrome');
  });

  test('without ECH the carrier profile is still honoured', () {
    expect(
        fpOf(node(),
            const SingboxRouteOptions(fingerprintOverride: 'randomized')),
        'randomized',
        reason: 'the per-carrier profile exists for a reason and ECH is the '
            'only thing that may overrule it');
  });

  test('without ECH a pinned fingerprint is still honoured', () {
    expect(fpOf(node(fingerprint: 'firefox'), const SingboxRouteOptions()),
        'firefox');
  });

  /// The override has to follow the ECH block, not the profile switch. ECH is
  /// emitted only for a node that can answer one, and these are the nodes that
  /// cannot: for them, dropping the carrier fingerprint and the fragment mask
  /// buys nothing and costs both defences.
  group('a node that gets no ECH block keeps its own settings', () {
    ProxyNode plainIp({String? fingerprint}) => ProxyNode(
          protocol: NodeProtocol.vless,
          server: '203.0.113.9', // not Cloudflare, so ECH cannot work
          port: 443,
          uuid: '00000000-0000-0000-0000-000000000000',
          tls: true,
          sni: 'example.com',
          network: 'ws',
          wsPath: '/ws',
          fingerprint: fingerprint,
          tag: 'n',
        );

    ProxyNode reality() => ProxyNode(
          protocol: NodeProtocol.vless,
          server: '203.0.113.9',
          port: 443,
          uuid: '00000000-0000-0000-0000-000000000000',
          tls: true,
          sni: 'example.com',
          realityPublicKey: 'aaaabbbbccccddddeeeeffff',
          fingerprint: 'firefox',
          tag: 'n',
        );

    Map<String, dynamic> tlsOf(ProxyNode n, SingboxRouteOptions o) {
      final Map<String, dynamic> m = SingboxConfig.buildMap(n, options: o);
      final List<dynamic> outs = m['outbounds'] as List<dynamic>;
      return (outs.first as Map<String, dynamic>)['tls']
          as Map<String, dynamic>;
    }

    test('a non-Cloudflare plain IP keeps its carrier fingerprint', () {
      const SingboxRouteOptions o = SingboxRouteOptions(
          ech: true, echConfig: 'K==', fingerprintOverride: 'randomized');
      expect(tlsOf(plainIp(), o).containsKey('ech'), isFalse,
          reason: 'ECH cannot work for this node, so none is sent');
      expect(fpOf(plainIp(), o), 'randomized',
          reason: 'with no ECH on the wire the carrier profile is all it has');
    });

    test('a non-Cloudflare plain IP keeps its fragmentation', () {
      const SingboxRouteOptions o =
          SingboxRouteOptions(ech: true, echConfig: 'K==');
      expect(tlsOf(plainIp(), o)['fragment'], isNotNull,
          reason: 'ECH switched fragmentation off while sending no ECH, so the '
              'real name went out in one plaintext packet');
    });

    test('a Reality node keeps the fingerprint it mimics', () {
      expect(
          fpOf(reality(),
              const SingboxRouteOptions(ech: true, echConfig: 'K==')),
          'firefox',
          reason: 'Reality never carries ECH, and the browser it imitates is '
              'part of what makes it work');
    });

    test('a Cloudflare node still gets both', () {
      const SingboxRouteOptions o = SingboxRouteOptions(
          ech: true, echConfig: 'K==', fingerprintOverride: 'randomized');
      expect(tlsOf(node(), o).containsKey('ech'), isTrue);
      expect(fpOf(node(), o), 'chrome');
    });
  });
}
