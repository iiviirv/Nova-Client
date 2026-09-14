import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link_builder.dart';

/// Aether links through the app's real import and share paths.
///
/// The options model has its own tests; this covers the wiring, which is where
/// a config is actually gained or lost. Building the link is where the gateway
/// gets reassembled from a node's server and port, and that reassembly is easy
/// to get silently wrong: an escaped interpolation compiles, analyses clean,
/// and emits the literal text of the expression instead of the address.
void main() {
  const String masque =
      'aether://162.159.198.1:443?protocol=masque&scan=balanced'
      '&noize=balanced&ip=v4&transport=h3#masque%20add%20test';
  const String wg =
      'aether://162.159.195.150:908?protocol=wg&scan=balanced'
      '&noize=balanced&ip=v4#wire%20add%20test';
  const String gool =
      'aether://?protocol=gool&scan=balanced&noize=balanced&ip=v4'
      '&outer=162.159.195.16%3A864&inner=162.159.192.1%3A2408'
      '#gool%20add%20test';

  test('a pasted link imports as an Aether node', () {
    final ProxyNode n = parseShareLink(masque)!;
    expect(n.protocol, NodeProtocol.aether);
    expect(n.server, '162.159.198.1');
    expect(n.port, 443);
    expect(n.tag, 'masque add test');
    expect(n.aetherOpts, contains('protocol=masque'));
  });

  test('a scanning config imports with no address, which is valid', () {
    final ProxyNode n = parseShareLink(gool)!;
    expect(n.protocol, NodeProtocol.aether);
    expect(n.server, isEmpty,
        reason: 'gool has no authority: the core scans for both hops');
    expect(n.port, 0);
    expect(n.aetherOpts, contains('outer=162.159.195.16%3A864'));
  });

  test('sharing reproduces the original link exactly', () {
    for (final String link in <String>[masque, wg, gool]) {
      final ProxyNode n = parseShareLink(link)!;
      expect(buildShareLink(n), link,
          reason: 'a config that changes on the way out stops importing into '
              'the client it came from');
    }
  });

  test('the gateway is a real address, not the text of an expression', () {
    // The specific failure this guards: '\$' inside a Dart string is an escaped
    // dollar, so an interpolation written that way compiles, analyses clean,
    // and emits the literal characters of the expression.
    final String out = buildShareLink(parseShareLink(masque)!);
    expect(out.contains(r'${'), isFalse,
        reason: 'an un-interpolated expression leaked into the link');
    expect(out, contains('aether://162.159.198.1:443?'));
  });

  test('an Aether node dials the local core, not the gateway', () {
    // The outbound is a socks one pointing at the Aether core's own port; the
    // gateway is that core's business. Getting this wrong would have sing-box
    // try to speak SOCKS to a Cloudflare edge.
    expect(NodeProtocol.aether.singboxType, 'socks');
    expect(NodeProtocol.aether.label, 'Aether');
  });
}
