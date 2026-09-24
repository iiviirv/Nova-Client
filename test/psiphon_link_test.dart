import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link_builder.dart';

/// A Psiphon profile has no address in it. Psiphon supplies its own servers,
/// so the node carries no server and no port and exists so the list has a row.
void main() {
  test('a psiphon link becomes a psiphon node', () {
    final ProxyNode? n = parseShareLink('psiphon://direct');
    expect(n, isNotNull);
    expect(n!.protocol, NodeProtocol.psiphon);
    expect(n.server, isEmpty, reason: 'there is no server to dial');
    expect(n.port, 0);
    expect(n.psiphonConf, 'psiphon://direct');
  });

  test('the aether mode is carried through and named differently', () {
    final ProxyNode? n = parseShareLink('psiphon://aether');
    expect(n!.psiphonConf, 'psiphon://aether');
    expect(n.tag, isNot(parseShareLink('psiphon://direct')!.tag),
        reason: 'the two modes must be tellable apart in the list');
  });

  test('the link re-shares exactly as it arrived', () {
    for (final String link in <String>['psiphon://direct', 'psiphon://aether']) {
      expect(buildShareLink(parseShareLink(link)!), link);
    }
  });

  test('the core is told to speak SOCKS5 to the engine', () {
    final ProxyNode n = parseShareLink('psiphon://direct')!;
    expect(n.protocol.singboxType, 'socks');
  });
}
