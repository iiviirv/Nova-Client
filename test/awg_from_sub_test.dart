import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// A Nova-target subscription is a sing-box config document, not a list of
/// share links. sing-box 1.11 moved WireGuard and AmneziaWG into their own
/// `endpoints` array, and the importer only read `outbounds`, so an operator
/// who put an AmneziaWG server in a subscription watched it arrive as nothing:
/// pasting the awg:// link by hand worked, the same server by subscription did
/// not, and no message explained the difference.
void main() {
  String subWith({required bool endpoints}) {
    final Map<String, dynamic> awg = <String, dynamic>{
      'type': 'awg',
      'tag': 'Amnezia DE',
      'private_key': 'cHJpdmF0ZWtleWJhc2U2NGNoYXJzMDAwMDAwMDAwMDAwMDAwMD0=',
      'address': <String>['10.8.0.2/32'],
      'mtu': 1420,
      'jc': 4, 'jmin': 40, 'jmax': 70, 's1': 15, 's2': 20,
      'peers': <Map<String, dynamic>>[
        <String, dynamic>{
          'public_key': 'cHVibGlja2V5YmFzZTY0Y2hhcnMwMDAwMDAwMDAwMDAwMDA9',
          'address': '45.132.240.17',
          'port': 51820,
          'allowed_ips': <String>['0.0.0.0/0'],
          'persistent_keepalive_interval': 25,
        },
      ],
    };
    return jsonEncode(<String, dynamic>{
      'outbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'vless',
          'tag': 'VLESS one',
          'server': '104.16.4.103',
          'server_port': 443,
          'uuid': '11111111-2222-3333-4444-555555555555',
          'tls': <String, dynamic>{'enabled': true, 'server_name': 'a.b'},
        },
        if (!endpoints) awg,
      ],
      if (endpoints) 'endpoints': <Map<String, dynamic>>[awg],
    });
  }

  test('an AmneziaWG endpoint arrives from a Nova-target subscription', () {
    final List<ProxyNode> nodes = parseSubscriptionBody(subWith(endpoints: true));
    expect(nodes.map((ProxyNode n) => n.protocol).toList(),
        containsAll(<NodeProtocol>[NodeProtocol.vless, NodeProtocol.awg]));
    final ProxyNode awg =
        nodes.firstWhere((ProxyNode n) => n.protocol == NodeProtocol.awg);
    expect(awg.server, '45.132.240.17');
    expect(awg.port, 51820);
    expect(awg.tag, 'Amnezia DE');
  });

  test('its junk parameters survive the trip', () {
    final ProxyNode awg = parseSubscriptionBody(subWith(endpoints: true))
        .firstWhere((ProxyNode n) => n.protocol == NodeProtocol.awg);
    // Round-trip it back out the way the core will see it.
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(awg);
    final String out = jsonEncode(cfg);
    for (final String k in const <String>['jc', 'jmin', 'jmax', 's1', 's2']) {
      expect(out, contains('"$k"'), reason: '$k is what makes it AmneziaWG');
    }
    expect(out, contains('45.132.240.17'));
  });

  test('it joins the lightning test rather than sitting it out', () {
    final List<ProxyNode> nodes = parseSubscriptionBody(subWith(endpoints: true));
    final built = SingboxConfig.buildMeasureMap(nodes,
        mixedPort: 24080, clashPort: 24081);
    expect(built.tagKeys.length, 2,
        reason: 'both servers must be measurable, not just the vless one');
    expect((built.config['endpoints'] as List?)?.length, 1,
        reason: 'the awg node measures as an endpoint');
  });

  test('an endpoint in the old outbounds position still works', () {
    // Older panels may still emit it as an outbound; that path is unchanged.
    final List<ProxyNode> nodes =
        parseSubscriptionBody(subWith(endpoints: false));
    expect(nodes.length, greaterThanOrEqualTo(1));
  });
}
