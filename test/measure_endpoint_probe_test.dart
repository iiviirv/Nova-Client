import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// AmneziaWG and WireGuard nodes have to be measurable.
///
/// They are sing-box `endpoints`, not outbounds. The Clash API lists them, so
/// they look testable, but a delay request against one fails immediately and
/// the core never attempts a dial at all: measured against two live servers,
/// both returned "An error occurred in the delay test" while a request routed
/// through the endpoint answered in 247ms and 291ms. Every AmneziaWG server
/// therefore read "no response" in the lightning test while connecting to the
/// very same server worked, which is what a user reported.
///
/// The fix is a local inbound per endpoint, pinned to it by a route rule, so a
/// measurement is a plain timed request rather than a Clash API call. This
/// guards the shape of that: a live server cannot be a unit test, but a missing
/// inbound or rule silently puts every AmneziaWG node back to "no response".
void main() {
  const String conf = '''
[Interface]
PrivateKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Address = 10.0.0.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 574
H1 = 180583858
H2 = 720512096
H3 = 1677969799
H4 = 1808982857

[Peer]
PublicKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Endpoint = 203.0.113.10:32418
AllowedIPs = 0.0.0.0/0
''';

  // Distinct server/port per node: identical endpoints are deduped out of the
  // pool before it is built, which is correct and not what this is testing.
  ProxyNode awg(String tag, String ip, int port) => ProxyNode(
        protocol: NodeProtocol.awg,
        server: ip,
        port: port,
        tag: tag,
        awgConf: conf
            .replaceAll('203.0.113.10:32418', '$ip:$port'),
      );

  ProxyNode ws(String tag) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'example.com',
        port: 443,
        tag: tag,
        uuid: '11111111-2222-3333-4444-555555555555',
        tls: true,
        network: 'ws',
        wsPath: '/x',
      );

  test('every endpoint gets its own inbound, pinned by a route rule', () {
    final ({
      Map<String, dynamic> config,
      Map<String, String> tagKeys,
      Map<String, int> endpointPorts
    }) built = SingboxConfig.buildMeasureMap(
      <ProxyNode>[awg('a', '203.0.113.10', 32418), ws('b'), awg('c', '203.0.113.11', 45874)],
      mixedPort: 19090,
      clashPort: 19091,
    );

    expect(built.endpointPorts.length, 2,
        reason: 'both AmneziaWG nodes need a port; the ws node does not');

    final List<Map<String, dynamic>> inbounds =
        (built.config['inbounds'] as List).cast<Map<String, dynamic>>();
    final List<Map<String, dynamic>> rules =
        ((built.config['route'] as Map)['rules'] as List)
            .cast<Map<String, dynamic>>();

    for (final MapEntry<String, int> e in built.endpointPorts.entries) {
      final Map<String, dynamic> inbound = inbounds.firstWhere(
          (Map<String, dynamic> i) => i['listen_port'] == e.value,
          orElse: () => <String, dynamic>{});
      expect(inbound['type'], 'mixed',
          reason: 'no inbound listening on the port for ${e.key}');
      // The rule must send that inbound to this endpoint and nowhere else.
      final Map<String, dynamic> rule = rules.firstWhere(
          (Map<String, dynamic> r) =>
              (r['inbound'] as List?)?.contains(inbound['tag']) ?? false,
          orElse: () => <String, dynamic>{});
      expect(rule['outbound'], e.key,
          reason: 'the inbound for ${e.key} is not pinned to it');
    }
  });

  test('a pool with no endpoints adds no inbounds and no rules', () {
    final built = SingboxConfig.buildMeasureMap(
      <ProxyNode>[ws('b')],
      mixedPort: 19090,
      clashPort: 19091,
    );
    expect(built.endpointPorts, isEmpty);
    expect((built.config['inbounds'] as List).length, 1);
    expect(((built.config['route'] as Map)['rules'] as List), isEmpty);
  });
}
