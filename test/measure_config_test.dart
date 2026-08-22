import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The measuring core's config ("test all servers through the core"): every
/// usable node, not the auto-select budget of 24; a local mixed inbound instead
/// of a TUN; the Clash API every host drives the run over; a tag -> node key map
/// so results land on the right rows; and none of the tunnel's routing, DNS or
/// rule-sets, which only cost the user startup time before the first number.
void main() {
  List<ProxyNode> nodes(int n) => <ProxyNode>[
        for (int i = 0; i < n; i++)
          parseShareLink('vless://00000000-0000-0000-0000-00000000000$i'
              '@h$i.example.net:443?type=ws&security=tls&sni=h$i.example.net'
              '&path=%2Fws#Node $i')!,
      ];

  test('every node is in the pool, well past the auto-select cap', () {
    final built = SingboxConfig.buildMeasureMap(nodes(40),
        mixedPort: 27080, clashPort: 27091);
    expect(built.tagKeys, hasLength(40));
    final List<dynamic> outs = built.config['outbounds'] as List<dynamic>;
    expect(
        outs
            .where((dynamic o) => (o as Map)['tag'].toString().startsWith('node-'))
            .length,
        40);
    // Compare: the tunnel config keeps the 24 budget.
    expect(
        (SingboxConfig.buildMultiMap(nodes(40))['outbounds'] as List<dynamic>)
            .where((dynamic o) => (o as Map)['tag'].toString().startsWith('node-'))
            .length,
        SingboxConfig.kMaxAutoNodes);
  });

  test('no TUN: a loopback mixed inbound and the Clash API instead', () {
    final built = SingboxConfig.buildMeasureMap(nodes(3),
        mixedPort: 27080, clashPort: 27091);
    final List<dynamic> ins = built.config['inbounds'] as List<dynamic>;
    expect(ins, hasLength(1));
    expect((ins.single as Map)['type'], 'mixed');
    expect((ins.single as Map)['listen'], '127.0.0.1');
    expect((ins.single as Map)['listen_port'], 27080);
    final Map<String, dynamic> exp =
        (built.config['experimental'] as Map).cast<String, dynamic>();
    expect((exp['clash_api'] as Map)['external_controller'], '127.0.0.1:27091');
  });

  test('tags map to the stable node keys in node-i order', () {
    final List<ProxyNode> n = nodes(3);
    final built = SingboxConfig.buildMeasureMap(n, mixedPort: 1, clashPort: 2);
    expect(built.tagKeys['node-0'], proxyNodeKey(n[0]));
    expect(built.tagKeys['node-2'], proxyNodeKey(n[2]));
  });

  test('a single node is still a pool of one', () {
    final List<ProxyNode> n = nodes(1);
    final built = SingboxConfig.buildMeasureMap(n, mixedPort: 1, clashPort: 2);
    expect(built.tagKeys, <String, String>{'node-0': proxyNodeKey(n[0])});
    expect((built.config['inbounds'] as List<dynamic>).single['type'], 'mixed');
  });

  test('no urltest group and no routing rules', () {
    // Both exist for the tunnel and cost a measuring core startup time it has
    // no use for. The group is the worst of them: sing-box sweeps the whole
    // pool the moment it starts, concurrently and cold, which is what reported
    // 400-800ms for mieru and NaiveProxy servers that answer in ~110ms warm.
    final built = SingboxConfig.buildMeasureMap(nodes(5),
        mixedPort: 1, clashPort: 2);
    final List<dynamic> outs = built.config['outbounds'] as List<dynamic>;
    expect(outs.any((dynamic o) => (o as Map)['type'] == 'urltest'), isFalse);
    expect(outs.any((dynamic o) => (o as Map)['tag'] == 'proxy'), isFalse);
    final Map<String, dynamic> route =
        (built.config['route'] as Map).cast<String, dynamic>();
    expect(route['rules'], isEmpty);
    expect(route['rule_set'], isNull);
    expect(jsonEncode(built.config), isNot(contains(SingboxConfig.ruleSetBaseToken)));
    // The tunnel's config still has all of it.
    expect((SingboxConfig.buildMultiMap(nodes(5))['outbounds'] as List<dynamic>)
        .any((dynamic o) => (o as Map)['type'] == 'urltest'), isTrue);
  });

  test('it keeps a resolver, because on mobile there is no other one', () {
    // This test used to assert the opposite, and that assumption shipped: the
    // measuring core on Android and iOS has a null localDNSTransport, so with
    // no `dns` block it cannot resolve a hostname at all. Every server on a
    // domain reported "no response" in about 50ms while bare-IP servers kept
    // working, which is how it survived testing against an all-IP free list.
    final Map<String, dynamic> dns =
        (SingboxConfig.buildMeasureMap(nodes(3), mixedPort: 1, clashPort: 2)
                .config['dns'] as Map)
            .cast<String, dynamic>();
    final List<dynamic> servers = dns['servers'] as List<dynamic>;
    expect(servers, hasLength(1), reason: 'a resolver, not the tunnel module');
    final Map<String, dynamic> server =
        (servers.single as Map).cast<String, dynamic>();
    // Direct, so it never loops back through the proxy being measured, and
    // IP-addressed, so it needs no bootstrap resolver of its own.
    expect(server['detour'], 'direct');
    expect(server['address'], contains('223.5.5.5'));
    expect(dns['final'], 'local');
    // Still none of the tunnel's rule-set machinery.
    expect(dns['rules'], isNull);
  });

  test('xhttp nodes join the pool as local socks exits when Xray is available',
      () {
    final List<ProxyNode> n = <ProxyNode>[
      ...nodes(2),
      parseShareLink('vless://00000000-0000-0000-0000-0000000000aa'
          '@x.example.net:443?type=xhttp&security=tls&sni=x.example.net'
          '&path=%2Fxh#X')!,
    ];
    final withX = SingboxConfig.buildMeasureMap(n,
        mixedPort: 1, clashPort: 2, includeXhttp: true, xhttpBasePort: 10808);
    expect(withX.tagKeys, hasLength(3));
    final List<dynamic> outs = withX.config['outbounds'] as List<dynamic>;
    final Map<String, dynamic> last = (outs.firstWhere((dynamic o) =>
            (o as Map)['tag'] == 'node-2') as Map)
        .cast<String, dynamic>();
    expect(last['type'], 'socks');
    expect(last['server_port'], 10808);
    expect(withX.tagKeys['node-2'], proxyNodeKey(n[2]));
    // Without Xray the xhttp node is left out, as before.
    final without = SingboxConfig.buildMeasureMap(n, mixedPort: 1, clashPort: 2);
    expect(without.tagKeys, hasLength(2));
  });


}
