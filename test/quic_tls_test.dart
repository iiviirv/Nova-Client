import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Hysteria2 never connected: the builder put uTLS (and TLS record
/// fragmentation) into every TLS block, and sing-box's QUIC dialer refuses a
/// uTLS config ("unsupported usage for uTLS"). Reproduced against a local
/// sing-box hysteria2 inbound with salamander; fixed by giving QUIC protocols
/// a plain TLS block. The salamander obfs itself must survive unchanged.
void main() {
  Map<String, dynamic> outbound(String link) {
    final ProxyNode n = parseShareLink(link)!;
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(n);
    return ((cfg['outbounds'] as List<dynamic>)
            .firstWhere((dynamic o) => (o as Map)['tag'] == 'proxy') as Map)
        .cast<String, dynamic>();
  }

  test('hysteria2 gets a plain TLS block (no utls, no fragment) and keeps obfs',
      () {
    final Map<String, dynamic> o = outbound(
        'hysteria2://pw@1.2.3.4:443?sni=h.example&insecure=1&obfs=salamander&obfs-password=s#H');
    final Map<String, dynamic> tls = (o['tls'] as Map).cast<String, dynamic>();
    expect(tls['enabled'], isTrue);
    expect(tls['server_name'], 'h.example');
    expect(tls['insecure'], isTrue);
    expect(tls.containsKey('utls'), isFalse);
    expect(tls.containsKey('fragment'), isFalse);
    expect((o['obfs'] as Map)['type'], 'salamander');
    expect((o['obfs'] as Map)['password'], 's');
  });

  test('tuic too', () {
    final Map<String, dynamic> o = outbound(
        'tuic://00000000-0000-0000-0000-000000000000:pw@1.2.3.4:443?sni=t.example&congestion_control=bbr#T');
    final Map<String, dynamic> tls = (o['tls'] as Map).cast<String, dynamic>();
    expect(tls.containsKey('utls'), isFalse);
    expect(tls.containsKey('fragment'), isFalse);
  });

  test('a TCP TLS node still forges a browser fingerprint', () {
    final Map<String, dynamic> o = outbound(
        'vless://00000000-0000-0000-0000-000000000000@v.example:443?type=ws&security=tls&sni=v.example&path=%2Fws#V');
    final Map<String, dynamic> tls = (o['tls'] as Map).cast<String, dynamic>();
    expect((tls['utls'] as Map)['enabled'], isTrue);
  });
}
