import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

void main() {
  test('hysteria2 link without bandwidth => BBR (no up/down in outbound)', () {
    final ProxyNode? n = parseShareLink(
        'hysteria2://pw@1.2.3.4:443?sni=example.com&insecure=1#H2');
    expect(n, isNotNull);
    expect(n!.protocol, NodeProtocol.hysteria2);
    expect(n.hy2UpMbps, isNull);
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(n);
    final Map<String, dynamic> out = (cfg['outbounds'] as List<dynamic>)
        .firstWhere((dynamic o) => o['tag'] == 'proxy') as Map<String, dynamic>;
    expect(out['type'], 'hysteria2');
    expect(out.containsKey('up_mbps'), isFalse);
    expect(out.containsKey('down_mbps'), isFalse);
  });

  test('hysteria2 link with bandwidth => Brutal (up/down emitted)', () {
    // Accept both spellings; the node emits upmbps/downmbps.
    final ProxyNode? n = parseShareLink(
        'hysteria2://pw@1.2.3.4:443?sni=example.com&insecure=1&upmbps=50&downmbps=100#H2');
    expect(n!.hy2UpMbps, 50);
    expect(n.hy2DownMbps, 100);
    final Map<String, dynamic> out = (SingboxConfig.buildMap(n)['outbounds']
            as List<dynamic>)
        .firstWhere((dynamic o) => o['tag'] == 'proxy') as Map<String, dynamic>;
    expect(out['up_mbps'], 50);
    expect(out['down_mbps'], 100);
  });

  test('sing-box spelling up_mbps/down_mbps is also parsed', () {
    final ProxyNode? n = parseShareLink(
        'hysteria2://pw@1.2.3.4:443?up_mbps=20&down_mbps=80#H2');
    expect(n!.hy2UpMbps, 20);
    expect(n.hy2DownMbps, 80);
  });

  test('user line-speed setting applies Brutal when the link has none', () {
    final ProxyNode? n = parseShareLink('hysteria2://pw@1.2.3.4:443#H2');
    const SingboxRouteOptions opts =
        SingboxRouteOptions(hy2UpMbps: 25, hy2DownMbps: 100);
    final Map<String, dynamic> out = (SingboxConfig.buildMap(n!, options: opts)['outbounds']
            as List<dynamic>)
        .firstWhere((dynamic o) => o['tag'] == 'proxy') as Map<String, dynamic>;
    expect(out['up_mbps'], 25);
    expect(out['down_mbps'], 100);
  });

  test('a link bandwidth overrides the user setting', () {
    final ProxyNode? n =
        parseShareLink('hysteria2://pw@1.2.3.4:443?upmbps=10&downmbps=40#H2');
    const SingboxRouteOptions opts =
        SingboxRouteOptions(hy2UpMbps: 25, hy2DownMbps: 100);
    final Map<String, dynamic> out = (SingboxConfig.buildMap(n!, options: opts)['outbounds']
            as List<dynamic>)
        .firstWhere((dynamic o) => o['tag'] == 'proxy') as Map<String, dynamic>;
    expect(out['up_mbps'], 10); // link wins
    expect(out['down_mbps'], 40);
  });
}
