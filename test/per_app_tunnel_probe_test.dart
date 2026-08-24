import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

ProxyNode _node() => parseShareLink(
      'vless://11111111-1111-1111-1111-111111111111@104.17.0.1:443'
      '?encryption=none&security=tls&sni=a.example.com&type=ws&path=%2F#n',
    )!;

List<Map<String, dynamic>> _inbounds(SingboxRouteOptions o) =>
    (SingboxConfig.buildMap(_node(), options: o)['inbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

void main() {
  test('an ordinary tunnel carries only the TUN', () {
    final List<Map<String, dynamic>> ins = _inbounds(const SingboxRouteOptions());
    expect(ins.map((Map<String, dynamic> i) => i['type']), <String>['tun']);
  });

  test('proxy mode carries only the loopback inbound', () {
    final List<Map<String, dynamic>> ins =
        _inbounds(const SingboxRouteOptions(mixedInboundPort: 2080));
    expect(ins.map((Map<String, dynamic> i) => i['type']), <String>['mixed']);
  });

  test('per-app routing carries the TUN AND a loopback inbound', () {
    // Without the second inbound the app has no way into its own tunnel, so the
    // dashboard reported the user's own IP and country as the exit whenever
    // Nova was not one of the apps they picked.
    final List<Map<String, dynamic>> ins = _inbounds(const SingboxRouteOptions(
      includePackages: <String>['org.telegram.messenger'],
      mixedInboundPort: 2080,
      tunWithLocalProxy: true,
    ));
    expect(ins.map((Map<String, dynamic> i) => i['type']),
        <String>['tun', 'mixed']);
    final Map<String, dynamic> tun =
        ins.firstWhere((Map<String, dynamic> i) => i['type'] == 'tun');
    expect(tun['include_package'], <String>['org.telegram.messenger']);
    final Map<String, dynamic> mixed =
        ins.firstWhere((Map<String, dynamic> i) => i['type'] == 'mixed');
    // Loopback only: the phone must not become an open relay for the network.
    expect(mixed['listen'], '127.0.0.1');
    expect(mixed['listen_port'], 2080);
  });
}
