import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

void main() {
  const String link =
      'mierus://u059f4b58ba948f29b88ed04bc8aa8163:9137d6959a521e78d9bc1589e3b03b65'
      '@vpn.novaproxy.qzz.io?port=6600&protocol=TCP&multiplexing=MULTIPLEXING_LOW#Azad%20mieru';

  test('parses a mierus:// link into a mieru node', () {
    final ProxyNode? n = parseShareLink(link);
    expect(n, isNotNull);
    expect(n!.protocol, NodeProtocol.mieru);
    expect(n.server, 'vpn.novaproxy.qzz.io');
    expect(n.port, 6600);
    expect(n.uuid, 'u059f4b58ba948f29b88ed04bc8aa8163'); // username slot
    expect(n.password, '9137d6959a521e78d9bc1589e3b03b65');
    expect(n.mieruTransport, 'TCP');
    expect(n.mieruMultiplexing, 'MULTIPLEXING_LOW');
  });

  test('emits a valid sing-box mieru outbound', () {
    final ProxyNode n = parseShareLink(link)!;
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(n);
    final Map<String, dynamic> out = (cfg['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> o) => o['type'] == 'mieru');
    expect(out['server'], 'vpn.novaproxy.qzz.io');
    expect(out['server_port'], 6600);
    expect(out['username'], 'u059f4b58ba948f29b88ed04bc8aa8163');
    expect(out['password'], '9137d6959a521e78d9bc1589e3b03b65');
    expect(out['transport'], 'TCP');
    expect(out['multiplexing'], 'MULTIPLEXING_LOW');
  });
}
