import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/xray/xray_config.dart';

/// The auto-select pool with xhttp folded in: xhttp nodes run on the Xray core,
/// and sing-box lists each as a local socks outbound so they get measured and
/// picked through the ordinary urltest, with the two cores' ports aligned.

ProxyNode _ws(String tag, String ip) => parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@$ip:443'
      '?encryption=none&security=tls&type=ws&host=h.example.com&path=%2Fp#$tag',
    )!;

ProxyNode _xhttp(String tag, String ip) => parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@$ip:443'
      '?encryption=none&security=tls&type=xhttp'
      '&sni=x.example.com&host=x.example.com&path=%2Fxh#$tag',
    )!;

void main() {
  test('XrayConfig.buildMulti gives each node its own socks inbound + route', () {
    final List<ProxyNode> nodes = <ProxyNode>[
      _xhttp('A', '104.17.1.1'),
      _xhttp('B', '104.17.2.2'),
    ];
    final Map<String, dynamic> cfg =
        XrayConfig.buildMultiMap(nodes, basePort: 20000);

    final List<dynamic> inb = cfg['inbounds'] as List<dynamic>;
    expect(inb.length, 2);
    expect((inb[0] as Map)['port'], 20000);
    expect((inb[0] as Map)['tag'], 'socks-in-0');
    expect((inb[1] as Map)['port'], 20001);
    expect((inb[1] as Map)['tag'], 'socks-in-1');

    // Two node outbounds (out-0, out-1) plus direct + block.
    final List<dynamic> out = cfg['outbounds'] as List<dynamic>;
    expect((out[0] as Map)['tag'], 'out-0');
    expect((out[0] as Map)['protocol'], 'vless');
    expect((out[1] as Map)['tag'], 'out-1');

    // Routing: a leading DNS-direct rule, then each inbound tag to its outbound.
    final List<dynamic> rules =
        (cfg['routing'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    expect((rules[0] as Map)['outboundTag'], 'direct',
        reason: 'DNS goes direct so it does not depend on the tunnel');
    expect((rules[0] as Map)['port'], 53);
    final List<dynamic> node =
        rules.where((dynamic r) => (r as Map).containsKey('inboundTag')).toList();
    expect((node[0] as Map)['inboundTag'], <String>['socks-in-0']);
    expect((node[0] as Map)['outboundTag'], 'out-0');
    expect((node[1] as Map)['inboundTag'], <String>['socks-in-1']);
    expect((node[1] as Map)['outboundTag'], 'out-1');
  });

  test('a mixed pool wraps xhttp as a socks outbound, ordered after real exits',
      () {
    final List<ProxyNode> nodes = <ProxyNode>[
      _xhttp('X', '104.17.9.9'),
      _ws('W1', '104.17.3.3'),
      _ws('W2', '104.17.4.4'),
    ];
    // Without includeXhttp the xhttp node is dropped entirely.
    final List<ProxyNode> plain = SingboxConfig.pickedMultiNodes(nodes);
    expect(plain.any((ProxyNode n) => n.network == 'xhttp'), isFalse);

    // With includeXhttp it is kept, and placed at the back of the pool.
    final List<ProxyNode> picked =
        SingboxConfig.pickedMultiNodes(nodes, includeXhttp: true);
    expect(picked.length, 3);
    expect(picked.last.network, 'xhttp',
        reason: 'real ws exits fill the pool first');

    final List<ProxyNode> xh = SingboxConfig.pickedXhttpNodes(nodes);
    expect(xh.length, 1);

    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(nodes,
        includeXhttp: true, xhttpBasePort: 20000);
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    // The urltest group lists node-0..node-2; the xhttp one (node-2) is a socks
    // outbound pointing at the Xray inbound port.
    final Map<String, dynamic> urltest = outs.firstWhere(
        (dynamic o) => (o as Map)['type'] == 'urltest') as Map<String, dynamic>;
    expect((urltest['outbounds'] as List<dynamic>).length, 3);
    final Map<String, dynamic> socks = outs.firstWhere((dynamic o) =>
        (o as Map)['type'] == 'socks' &&
        (o)['tag'] == 'node-2') as Map<String, dynamic>;
    expect(socks['server'], '127.0.0.1');
    expect(socks['server_port'], 20000);
  });

  test('an all-xhttp subscription still connects when the core is available',
      () {
    final List<ProxyNode> nodes = <ProxyNode>[
      _xhttp('A', '104.17.1.1'),
      _xhttp('B', '104.17.2.2'),
    ];
    // Without the core it throws (nothing sing-box can run).
    expect(() => SingboxConfig.buildMultiMap(nodes), throwsFormatException);
    // With the core the two nodes become a measured pool of socks exits.
    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(nodes,
        includeXhttp: true, xhttpBasePort: 20000);
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    final Iterable<dynamic> socks =
        outs.where((dynamic o) => (o as Map)['type'] == 'socks');
    expect(socks.length, 2);
  });

  test('the xhttp bridge resolves the sniffed domain to an IP for Xray', () {
    final Map<String, dynamic> route =
        (jsonDecode(SingboxConfig.buildXraySocksBridge(10808))
            as Map<String, dynamic>)['route'] as Map<String, dynamic>;
    final List<dynamic> rules = route['rules'] as List<dynamic>;
    // sniff runs first (to get the domain), resolve runs last (before proxy).
    expect((rules.first as Map)['action'], 'sniff');
    expect((rules.last as Map)['action'], 'resolve',
        reason: 'Xray must receive an IP, not a domain it cannot resolve');
  });
}
