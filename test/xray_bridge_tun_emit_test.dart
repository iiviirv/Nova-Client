import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

// The TUN-mode xhttp bridge must route the server IP straight out `direct`, and
// that rule must come first so no later rule steers Xray's own dial back into
// the socks->Xray chain (the loop this fix exists to prevent). Validated against
// the shipped sing-box binary during development; this guards the shape.
void main() {
  test('xray bridge routes the server IP direct, and that rule is first', () {
    const String serverIp = '203.0.113.7';
    final Map<String, dynamic> cfg = SingboxConfig.buildXraySocksBridgeMap(
      10808,
      directServerIp: serverIp,
    );
    final List<dynamic> rules =
        (cfg['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    final Map<String, dynamic> first = rules.first as Map<String, dynamic>;
    expect(first['ip_cidr'], <String>['$serverIp/32']);
    expect(first['outbound'], 'direct');
  });

  test('no directServerIp means no loop-break rule (proxy mode)', () {
    final Map<String, dynamic> cfg =
        SingboxConfig.buildXraySocksBridgeMap(10808);
    final List<dynamic> rules =
        (cfg['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    expect(
      rules.every((dynamic r) => (r as Map<String, dynamic>)['ip_cidr'] == null),
      isTrue,
    );
  });
}
