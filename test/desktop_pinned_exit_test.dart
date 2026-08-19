import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';

/// A user on desktop pinned the Germany server and got a Netherlands exit IP.
/// The desktop controller resolved the whole subscription and handed it all to
/// the urltest, which auto-picked the fastest node and ignored the pin. Mobile
/// honoured pins; desktop must do the same.
///
/// The subscription here is two nodes on different hosts. Pinning one must
/// produce a config whose outbounds contain ONLY that node's server.
void main() {
  const String de = 'vless://11111111-1111-1111-1111-111111111111@de.example.net:443'
      '?type=ws&security=tls&sni=de.example.net&path=%2Fws#Germany';
  const String nl = 'vless://22222222-2222-2222-2222-222222222222@nl.example.net:443'
      '?type=ws&security=tls&sni=nl.example.net&path=%2Fws#Netherlands';
  final String subBody = base64.encode(utf8.encode('$de\n$nl\n'));

  DesktopProxyController controller() {
    final DesktopProxyController c = DesktopProxyController();
    // Serve the two-node subscription from memory instead of the network.
    c.subFetcherProvider = () => (Uri _) async => subBody;
    return c;
  }

  ProxyProfile profile({String? pinnedNode, String? pinnedName}) => ProxyProfile(
        id: 'p1',
        name: 'Live sub',
        kind: ProxyKind.subscription,
        uri: '',
        subscriptionUrl: 'https://sub.example.net/u',
        updatedAt: DateTime(2026, 8, 18),
        pinnedNode: pinnedNode,
        pinnedName: pinnedName,
      );

  Set<String> outboundServers(String cfg) {
    final Map<String, dynamic> m = jsonDecode(cfg) as Map<String, dynamic>;
    final List<dynamic> outs = (m['outbounds'] as List<dynamic>?) ?? <dynamic>[];
    return <String>{
      for (final dynamic o in outs)
        if (o is Map && o['server'] is String) o['server'] as String,
    };
  }

  test('with no pin, both servers are in the pool (auto-select)', () async {
    final String cfg = await controller().buildConfigForTest(profile());
    expect(outboundServers(cfg), containsAll(<String>['de.example.net', 'nl.example.net']));
  });

  test('pinning Germany yields a config with ONLY the Germany server', () async {
    final ProxyNode deNode = parseShareLink(de)!;
    final String cfg = await controller().buildConfigForTest(
      profile(pinnedNode: proxyNodeKey(deNode), pinnedName: 'Germany'),
    );
    final Set<String> servers = outboundServers(cfg);
    expect(servers, contains('de.example.net'));
    expect(servers, isNot(contains('nl.example.net')),
        reason: 'the pinned exit must not be widened back into a urltest pool');
  });

  test('a stale key still matches by the pinned NAME (clean-IP rotation)',
      () async {
    // The key no longer matches anything (the panel rotated the address), but
    // the name the user pinned is still in the list, so it must be honoured.
    final String cfg = await controller().buildConfigForTest(
      profile(pinnedNode: 'stale-key-that-matches-nothing', pinnedName: 'Germany'),
    );
    final Set<String> servers = outboundServers(cfg);
    expect(servers, contains('de.example.net'));
    expect(servers, isNot(contains('nl.example.net')));
  });

  test('exitName resolves a node key to its panel-given name', () async {
    final DesktopProxyController c = controller();
    await c.buildConfigForTest(profile());
    final ProxyNode nlNode = parseShareLink(nl)!;
    expect(c.exitName(proxyNodeKey(nlNode)), 'Netherlands');
    expect(c.exitName(null), isNull);
  });
}
