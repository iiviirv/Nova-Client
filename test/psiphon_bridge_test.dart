import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// sing-box forwarding into the Psiphon engine.
///
/// The trap this pins is the one MasterDNS hit first: in full device mode every
/// packet is routed into the tunnel sing-box provides, and the engine is what
/// that tunnel is made of. Without an exclusion the engine's own dials to
/// Psiphon's servers are routed into itself, and nothing ever connects.
void main() {
  Map<String, dynamic> route(Map<String, dynamic> cfg) =>
      cfg['route'] as Map<String, dynamic>;
  List<dynamic> rules(Map<String, dynamic> cfg) =>
      route(cfg)['rules'] as List<dynamic>;

  test('traffic is handed to the engine on its loopback port', () {
    final cfg = SingboxConfig.buildPsiphonSocksBridgeMap(1081);
    final out = (cfg['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
    expect(out['type'], 'socks');
    expect(out['tag'], 'proxy');
    expect(out['server'], '127.0.0.1');
    expect(out['server_port'], 1081);
    expect(out['version'], '5');
  });

  test('the engine itself is routed direct, ahead of everything else', () {
    final cfg = SingboxConfig.buildPsiphonSocksBridgeMap(1081,
        enginePath: '/opt/nova/psiphon');
    final first = rules(cfg).first as Map<String, dynamic>;
    expect(first['process_path'], <String>['/opt/nova/psiphon']);
    expect(first['outbound'], 'direct');
    expect(route(cfg)['find_process'], isTrue,
        reason: 'the process rule cannot match unless lookup is enabled');
  });

  test('the exclusion comes before the DNS hijack, or it never matches', () {
    final cfg = SingboxConfig.buildPsiphonSocksBridgeMap(1081,
        enginePath: '/opt/nova/psiphon');
    final List<dynamic> r = rules(cfg);
    final int engineAt =
        r.indexWhere((x) => (x as Map).containsKey('process_path'));
    final int hijackAt = r.indexWhere((x) =>
        (x as Map)['action'] == 'hijack-dns' || x.containsKey('hijack_dns'));
    expect(engineAt, 0);
    if (hijackAt != -1) expect(engineAt, lessThan(hijackAt));
  });

  test('proxy mode needs no exclusion, so none is added', () {
    // Without a TUN there is nothing to route the engine into, and a
    // process rule on a path that is not running would only add a lookup.
    final cfg = SingboxConfig.buildPsiphonSocksBridgeMap(1081);
    expect(rules(cfg).where((x) => (x as Map).containsKey('process_path')),
        isEmpty);
    expect(route(cfg)['find_process'], isNot(isTrue));
  });
}
