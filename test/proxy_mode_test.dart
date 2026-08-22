import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Proxy mode: Nova serves a local SOCKS5/HTTP port instead of taking the whole
/// device. The config is the difference, so the config is what this pins down.
void main() {
  List<ProxyNode> nodes(int n) => <ProxyNode>[
        for (int i = 0; i < n; i++)
          parseShareLink('vless://00000000-0000-0000-0000-00000000000$i'
              '@h$i.example.net:443?type=ws&security=tls&sni=h$i.example.net'
              '&path=%2Fws#Node $i')!,
      ];

  Map<String, dynamic> inbound(Map<String, dynamic> config) =>
      ((config['inbounds'] as List<dynamic>).single as Map)
          .cast<String, dynamic>();

  test('with no port it is a TUN, as it always was', () {
    for (final Map<String, dynamic> cfg in <Map<String, dynamic>>[
      SingboxConfig.buildMap(nodes(1).single),
      SingboxConfig.buildMultiMap(nodes(3)),
    ]) {
      expect(inbound(cfg)['type'], 'tun');
    }
  });

  test('with a port it is a loopback mixed inbound and no TUN at all', () {
    const SingboxRouteOptions proxy =
        SingboxRouteOptions(mixedInboundPort: 2080);
    for (final Map<String, dynamic> cfg in <Map<String, dynamic>>[
      SingboxConfig.buildMap(nodes(1).single, options: proxy),
      SingboxConfig.buildMultiMap(nodes(3), options: proxy),
    ]) {
      final Map<String, dynamic> i = inbound(cfg);
      expect(i['type'], 'mixed');
      expect(i['listen_port'], 2080);
      // Loopback only: a phone on a shared network must not become an open
      // relay for everyone else on it.
      expect(i['listen'], '127.0.0.1');
      expect((cfg['inbounds'] as List<dynamic>).length, 1,
          reason: 'no TUN alongside it, or the device would be tunnelled too');
    }
  });

  test('everything that makes a node connect is unchanged by proxy mode', () {
    // Only the inbound differs. Same outbounds, same routing, same anti-DPI, so
    // a server that works in full-device mode works here.
    final List<ProxyNode> n = nodes(3);
    final Map<String, dynamic> tun = SingboxConfig.buildMultiMap(n);
    final Map<String, dynamic> proxy = SingboxConfig.buildMultiMap(n,
        options: const SingboxRouteOptions(mixedInboundPort: 2080));
    expect(proxy['outbounds'], tun['outbounds']);
    expect(proxy['route'], tun['route']);
    expect(proxy['dns'], tun['dns']);
  });

  test('the port survives copyWith, which is how it reaches the builder', () {
    const SingboxRouteOptions base = SingboxRouteOptions();
    expect(base.mixedInboundPort, isNull);
    expect(base.copyWith(mixedInboundPort: 1080).mixedInboundPort, 1080);
  });
}
