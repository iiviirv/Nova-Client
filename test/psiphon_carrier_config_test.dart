import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Asked for 2026-10-10: let Psiphon chain over any config, not only WARP.
///
/// The reason is Google. It refuses requests arriving from a Cloudflare
/// address, so Gemini and Google sign-in answer "not available in your region"
/// through a Worker config however well it carries everything else. Psiphon's
/// exit is not a Cloudflare address, so chaining it over whatever config gets
/// the user out of their country fixes that.
///
/// The whole chain lives in one sing-box:
///
///     device -> proxy outbound (SOCKS to the engine) -> engine
///     engine -> direct by process path, so its dials are not routed into
///               itself
///     engine -> 127.0.0.1:carrierPort -> this config's listener -> carrier
void main() {
  ProxyNode node() => ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'edge.example.com',
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        sni: 'edge.example.com',
        network: 'ws',
        wsPath: '/ws',
        tag: 'carrier-node',
      );

  Map<String, dynamic> build({String? enginePath = '/data/app/libpsiphon.so'}) =>
      SingboxConfig.buildPsiphonOverCarrierMap(
        1080,
        carrier: node(),
        carrierPort: 1081,
        enginePath: enginePath,
      );

  List<Map<String, dynamic>> listOf(Map<String, dynamic> m, String k) =>
      (m[k] as List<dynamic>).cast<Map<String, dynamic>>();

  test('the device goes into the engine, not into the carrier', () {
    final List<Map<String, dynamic>> outs = listOf(build(), 'outbounds');
    final Map<String, dynamic> proxy =
        outs.firstWhere((Map<String, dynamic> o) => o['tag'] == 'proxy');
    expect(proxy['type'], 'socks');
    expect(proxy['server_port'], 1080,
        reason: 'the default outbound is the engine; the carrier is reached '
            'only from the listener');
  });

  test('the carrier is a real outbound built from the chosen node', () {
    final Map<String, dynamic> carrier = listOf(build(), 'outbounds')
        .firstWhere((Map<String, dynamic> o) => o['tag'] == 'carrier');
    expect(carrier['type'], 'vless');
    expect(carrier['server'], 'edge.example.com');
    expect(carrier['server_port'], 443);
  });

  test('there is a loopback listener for the engine to dial', () {
    final Map<String, dynamic> inb = listOf(build(), 'inbounds').firstWhere(
        (Map<String, dynamic> i) =>
            i['tag'] == SingboxConfig.kPsiphonCarrierInbound);
    expect(inb['type'], 'mixed');
    expect(inb['listen'], '127.0.0.1',
        reason: 'loopback only. A carrier hop reachable from the LAN would '
            'let anything on the network out through the user config');
    expect(inb['listen_port'], 1081);
  });

  test('what arrives on that listener goes to the carrier, nothing else does',
      () {
    final List<dynamic> rules =
        (build()['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    final List<Map<String, dynamic>> toCarrier = rules
        .cast<Map<String, dynamic>>()
        .where((Map<String, dynamic> r) => r['outbound'] == 'carrier')
        .toList();
    expect(toCarrier.length, 1, reason: 'exactly one way into the carrier');
    expect(toCarrier.single['inbound'],
        <String>[SingboxConfig.kPsiphonCarrierInbound],
        reason: 'matched on the listener, not on an address, so nothing the '
            'user browses can be mistaken for the carrier');
  });

  test('the engine still gets out of its own tunnel first', () {
    final List<dynamic> rules =
        (build()['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    final Map<String, dynamic> first = rules.first as Map<String, dynamic>;
    expect(first['process_path'], <String>['/data/app/libpsiphon.so']);
    expect(first['outbound'], 'direct',
        reason: 'without this the engine dials Psiphon through the tunnel it '
            'is itself providing, and nothing ever connects. It has to stay '
            'ahead of the carrier rule, because the engine reaching loopback '
            'is how the carrier is reached at all');
  });

  test('with no engine path the carrier rule is still first', () {
    final List<dynamic> rules = (build(enginePath: null)['route']
        as Map<String, dynamic>)['rules'] as List<dynamic>;
    expect((rules.first as Map<String, dynamic>)['outbound'], 'carrier');
  });
}
