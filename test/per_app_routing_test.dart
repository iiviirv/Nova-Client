import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

ProxyNode _node() => parseShareLink(
      'vless://11111111-1111-1111-1111-111111111111@104.17.0.1:443'
      '?encryption=none&security=tls&sni=a.example.com&type=ws&path=%2F#n',
    )!;

Map<String, dynamic> _tun(SingboxRouteOptions o) {
  final Map<String, dynamic> cfg = SingboxConfig.buildMap(_node(), options: o);
  final List<dynamic> inbounds = cfg['inbounds'] as List<dynamic>;
  return inbounds
      .cast<Map<String, dynamic>>()
      .firstWhere((Map<String, dynamic> i) => i['type'] == 'tun');
}

void main() {
  test('no per-app selection leaves the TUN inbound alone', () {
    final Map<String, dynamic> tun = _tun(const SingboxRouteOptions());
    expect(tun.containsKey('include_package'), isFalse);
    expect(tun.containsKey('exclude_package'), isFalse);
  });

  test('"only these apps" emits include_package', () {
    final Map<String, dynamic> tun = _tun(const SingboxRouteOptions(
        includePackages: <String>['org.telegram.messenger', 'com.brave.browser']));
    expect(tun['include_package'],
        <String>['org.telegram.messenger', 'com.brave.browser']);
    expect(tun.containsKey('exclude_package'), isFalse);
  });

  test('"all except these" emits exclude_package', () {
    final Map<String, dynamic> tun = _tun(
        const SingboxRouteOptions(excludePackages: <String>['com.bank.app']));
    expect(tun['exclude_package'], <String>['com.bank.app']);
    expect(tun.containsKey('include_package'), isFalse);
  });

  test('the mode decides which list the config carries, never both', () {
    // Android's VpnService.Builder throws if a config uses both lists, so the
    // controller must only ever fill one of them.
    final AppRouting r = AppRouting();
    expect(r.mode, AppRoutingMode.all);
    expect(r.includePackages, isEmpty);
    expect(r.excludePackages, isEmpty);

    r.setMode(AppRoutingMode.only);
    r.toggle('org.telegram.messenger', true);
    expect(r.includePackages, <String>['org.telegram.messenger']);
    expect(r.excludePackages, isEmpty);

    // Switching mode reuses the same picks rather than making the user redo them.
    r.setMode(AppRoutingMode.except);
    expect(r.excludePackages, <String>['org.telegram.messenger']);
    expect(r.includePackages, isEmpty);

    r.setMode(AppRoutingMode.all);
    expect(r.includePackages, isEmpty);
    expect(r.excludePackages, isEmpty);
    expect(r.isActive, isFalse);
  });
}
