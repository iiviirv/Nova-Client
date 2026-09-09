import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The SNI-block bypass reaching the servers that need it most.
///
/// Reported from Iran after a DPI update: the finalmask values that get free
/// configs through changed, and pasting the new ones into the app "still does
/// not work". The values were fine. The bypass was gated on isCleanIpFronted,
/// meaning a node already addressed by IP with a separate TLS name, so every
/// domain-addressed server was silently excluded.
///
/// That is backwards. A domain-addressed node puts the real name in its
/// ClientHello, which is precisely what the SNI filter matches, so it is the
/// case that needs the record split most. And the failure was invisible: the
/// user got no mask at all rather than a different one, with nothing on screen
/// to say so.
void main() {
  const String newMask =
      '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
      '"lengths":["0","104","1"],"delays":["0"],"maxSplit":"0"}},'
      '{"type":"fragment","settings":{"packets":"1-1","lengths":["114","1"],'
      '"delays":["1"],"maxSplit":"11"}}]}';

  ProxyNode node({
    required String server,
    String? sni,
    bool tls = true,
    NodeProtocol protocol = NodeProtocol.vless,
    String? reality,
    String? fingerprint,
  }) =>
      ProxyNode(
        protocol: protocol,
        server: server,
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: tls,
        sni: sni,
        network: 'ws',
        wsPath: '/ws',
        realityPublicKey: reality,
        fingerprint: fingerprint,
        tag: 'n',
      );

  String cfgFor(ProxyNode n) => jsonEncode(SingboxConfig.buildMap(
        n,
        options: SingboxRouteOptions(
          hardenTls: true,
          bypassFragmentMask: newMask,
        ),
      ));

  bool carriesMask(String s) => s.contains('"104"') && s.contains('"114"');

  group('the mask the user set is the mask that is sent', () {
    test('a domain-addressed node now gets it', () {
      expect(carriesMask(cfgFor(node(server: 'a.example.com', sni: 'a.example.com'))),
          isTrue,
          reason: 'this is the node whose ClientHello carries the real name, so '
              'excluding it defeated the point of the bypass');
    });

    test('a clean-IP fronted node still gets it', () {
      expect(
          carriesMask(cfgFor(node(server: '104.16.4.103', sni: 'a.example.com'))),
          isTrue);
    });

    test('an IP-addressed node with no TLS name gets it too', () {
      // Much of the published free list is bare IPs. Before, whether these were
      // hardened depended on a TLS name being present, which is not something
      // the user can see or control.
      expect(carriesMask(cfgFor(node(server: '104.16.4.103'))), isTrue);
    });
  });

  group('the exclusions are the ones the bypass cannot help', () {
    test('Reality keeps the handshake its link pinned', () {
      // Its ClientHello already imitates a real session, so there is nothing
      // for a record split to hide, and hardening would actively break it:
      // hardened() overwrites the pinned fingerprint with 'unsafe', which the
      // core does not know and _singboxFingerprint quietly maps to 'chrome'.
      // A link that asked for firefox would forge the wrong ClientHello.
      //
      // Asserting the absence of the mask alone proves nothing here: the emit
      // path excludes Reality on its own line, so that assertion held whether
      // or not this node was hardened. The fingerprint is what actually moves.
      final String s = cfgFor(node(
          server: 'a.example.com',
          sni: 'a.example.com',
          reality: 'abc123',
          fingerprint: 'firefox'));
      expect(carriesMask(s), isFalse);
      expect(s, contains('"fingerprint":"firefox"'),
          reason: 'hardening a Reality node swaps its pinned fingerprint for '
              'unsafe, which maps to chrome and changes which ClientHello it '
              'forges');
    });

    test('a node with no TLS has no ClientHello to split', () {
      expect(carriesMask(cfgFor(node(server: 'a.example.com', tls: false))), isFalse);
    });

    test('QUIC protocols are not carried over TCP', () {
      // Record and segment splitting are TCP tricks; applying them to Hysteria2
      // once broke every such node.
      //
      // Honest note for whoever mutation-tests this next: removing the
      // isUdpNative guard from _maybeHarden does NOT fail this test, and no
      // test can currently catch it. Measured for both hysteria2 and tuic, the
      // emitted outbound is byte-identical hardened or not, because the QUIC
      // builders write their own small TLS block and never read fingerprint,
      // cipher_suites or fragmentMask. The guard is kept because it costs
      // nothing and becomes load-bearing the moment a QUIC builder reuses the
      // shared TLS block; this assertion is what would fail on that day.
      expect(
          carriesMask(cfgFor(node(
              server: 'a.example.com',
              sni: 'a.example.com',
              protocol: NodeProtocol.hysteria2))),
          isFalse);
    });
  });

  test('with the bypass off, nothing is rewritten', () {
    final String s = jsonEncode(SingboxConfig.buildMap(
      node(server: 'a.example.com', sni: 'a.example.com'),
      options: SingboxRouteOptions(bypassFragmentMask: newMask),
    ));
    expect(carriesMask(s), isFalse,
        reason: 'the bypass is an explicit per-profile choice');
  });
}
