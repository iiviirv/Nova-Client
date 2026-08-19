import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

/// The AmneziaWG core parses the peer Endpoint with ParseAddr and rejects a
/// hostname, so `Endpoint = vpn.example.com:51820` FATALs at startup. Mobile
/// has resolved such endpoints to an IP since the AWG core shipped; desktop did
/// not, so the same `.conf` connected on Android and died on Windows (shown as
/// a UAC problem) and macOS. These pin the desktop rewrite.
void main() {
  const String confDomain = '[Interface]\n'
      'PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n'
      'Address = 10.9.0.2/32\n'
      'Jc = 4\nJmin = 40\nJmax = 70\nS1 = 0\nS2 = 0\n'
      'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
      '[Peer]\n'
      'PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\n'
      'AllowedIPs = 0.0.0.0/0\n'
      'Endpoint = vpn.example.com:51820\n'
      'PersistentKeepalive = 25\n';

  Map<String, dynamic> endpointOf(String cfg) {
    final Map<String, dynamic> m = jsonDecode(cfg) as Map<String, dynamic>;
    final List<dynamic> eps = (m['endpoints'] as List<dynamic>?) ?? <dynamic>[];
    expect(eps, hasLength(1), reason: 'one awg endpoint expected');
    return (eps.single as Map).cast<String, dynamic>();
  }

  test('a domain Endpoint is rewritten to the resolved IP in the desktop config',
      () async {
    final DesktopProxyController c = DesktopProxyController()
      ..hostResolverOverride = (String host) async {
        expect(host, 'vpn.example.com');
        return '203.0.113.7';
      };
    final String cfg = await c.buildConfigForTest(ProxyProfile(
      id: 'awg1',
      name: 'Office',
      kind: ProxyKind.awg,
      uri: confDomain,
      updatedAt: DateTime(2026, 8, 19),
    ));
    final Map<String, dynamic> ep = endpointOf(cfg);
    expect(ep['type'], 'awg');
    final Map<String, dynamic> peer =
        ((ep['peers'] as List<dynamic>).single as Map).cast<String, dynamic>();
    expect(peer['address'], '203.0.113.7');
    expect(peer['port'], 51820);
  });

  test('an unresolvable domain passes through so the core reports it',
      () async {
    final DesktopProxyController c = DesktopProxyController()
      ..hostResolverOverride = (String _) async => null;
    final List<ProxyNode> out = await c.resolveEndpointHostsForTest(
        <ProxyNode>[ProxyNode.fromAwgConf(confDomain)]);
    expect(out.single.awgConf, contains('vpn.example.com:51820'));
  });

  test('a numeric Endpoint is never looked up', () async {
    int lookups = 0;
    final DesktopProxyController c = DesktopProxyController()
      ..hostResolverOverride = (String _) async {
        lookups++;
        return '1.1.1.1';
      };
    final String conf =
        confDomain.replaceFirst('vpn.example.com:51820', '198.51.100.9:51820');
    final List<ProxyNode> out = await c
        .resolveEndpointHostsForTest(<ProxyNode>[ProxyNode.fromAwgConf(conf)]);
    expect(lookups, 0);
    expect(out.single.awgConf, contains('198.51.100.9:51820'));
  });
}
