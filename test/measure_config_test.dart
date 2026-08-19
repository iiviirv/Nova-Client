import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The measuring core's config ("test all servers through the core"): every
/// usable node, not the auto-select budget of 24; a local mixed inbound instead
/// of a TUN; the Clash API the desktop controller drives; and a tag -> node key
/// map so results land on the right rows.
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
    final Map<String, dynamic> group = (outs.firstWhere(
        (dynamic o) => (o as Map)['tag'] == 'proxy') as Map).cast<String, dynamic>();
    expect(group['type'], 'urltest');
    expect((group['outbounds'] as List<dynamic>).length, 40);
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

  test('a single node still gets a urltest group (the group stream is what '
      'Android reads)', () {
    final List<ProxyNode> n = nodes(1);
    final built = SingboxConfig.buildMeasureMap(n, mixedPort: 1, clashPort: 2);
    expect(built.tagKeys, <String, String>{'node-0': proxyNodeKey(n[0])});
    final List<dynamic> outs = built.config['outbounds'] as List<dynamic>;
    expect(outs.any((dynamic o) => (o as Map)['type'] == 'urltest'), isTrue);
    expect((built.config['inbounds'] as List<dynamic>).single['type'], 'mixed');
  });

  test('without a clash port no API is configured (mobile measuring core)', () {
    final built = SingboxConfig.buildMeasureMap(nodes(2), mixedPort: 1);
    final Map<String, dynamic>? exp =
        (built.config['experimental'] as Map?)?.cast<String, dynamic>();
    expect(exp?['clash_api'], isNull);
  });
}
