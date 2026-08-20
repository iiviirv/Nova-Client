import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Settings > Routing > URL test drives the urltest group: the address every
/// measurement fetches, the re-test interval and the switch tolerance.
void main() {
  List<ProxyNode> nodes(int n) => <ProxyNode>[
        for (int i = 0; i < n; i++)
          parseShareLink('vless://00000000-0000-0000-0000-00000000000$i'
              '@h$i.example.net:443?type=ws&security=tls&sni=h$i.example.net'
              '&path=%2Fws#Node $i')!,
      ];

  Map<String, dynamic> group(Map<String, dynamic> cfg) =>
      ((cfg['outbounds'] as List<dynamic>)
              .firstWhere((dynamic o) => (o as Map)['tag'] == 'proxy') as Map)
          .cast<String, dynamic>();

  test('defaults: plain-http gstatic, 180s, 50ms', () {
    final Map<String, dynamic> g = group(SingboxConfig.buildMultiMap(nodes(3)));
    expect(g['url'], 'http://www.gstatic.com/generate_204');
    expect(g['interval'], '180s');
    expect(g['tolerance'], 50);
  });

  test('the user\'s values land in the config, clamped', () {
    final Map<String, dynamic> g = group(SingboxConfig.buildMultiMap(nodes(3),
        options: const SingboxRouteOptions(
            urlTestUrl: 'https://www.google.com/generate_204',
            urlTestIntervalSec: 400,
            urlTestToleranceMs: 20)));
    expect(g['url'], 'https://www.google.com/generate_204');
    expect(g['interval'], '400s');
    expect(g['tolerance'], 20);
    final Map<String, dynamic> clamped = group(SingboxConfig.buildMultiMap(
        nodes(3),
        options: const SingboxRouteOptions(urlTestIntervalSec: 1, urlTestUrl: '  ')));
    expect(clamped['interval'], '10s');
    expect(clamped['url'], 'http://www.gstatic.com/generate_204');
  });
}
