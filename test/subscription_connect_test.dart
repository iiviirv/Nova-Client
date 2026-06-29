import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// Regression test for the "Unsupported or invalid profile link" bug: a
/// subscription profile (empty uri, URL in subscriptionUrl) must resolve to a
/// real connectable node instead of null.
void main() {
  test('subscription profile resolves to a connectable node', () async {
    final profile = ProxyProfile(
      id: 't',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl:
          'https://sub.lillio.org/sub?sub=user1&key=f2190e7f987c',
    );

    final node = await resolveProfileNode(profile);

    expect(node, isNotNull, reason: 'subscription should resolve to a node');
    expect(node!.uuid, isNotNull);
    expect(node.server, isNotEmpty);
    expect(node.tls, isTrue);
    // ignore: avoid_print
    print('resolved: ${node.server}:${node.port} uuid=${node.uuid} '
        'ws=${node.wsPath} host=${node.wsHost} sni=${node.sni}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('subscription expands to many nodes and builds a capped urltest',
      () async {
    final profile = ProxyProfile(
      id: 't',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl:
          'https://sub.lillio.org/sub?sub=user1&key=f2190e7f987c',
    );

    final nodes = await resolveProfileNodes(profile);
    expect(nodes.length, greaterThan(1),
        reason: 'a subscription should expand to multiple nodes');

    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(nodes);
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    final Map<String, dynamic> auto = outs.firstWhere(
      (dynamic o) => (o as Map)['tag'] == 'proxy',
    ) as Map<String, dynamic>;

    expect(auto['type'], 'urltest', reason: 'fastest-node auto-selector');
    final int members = (auto['outbounds'] as List<dynamic>).length;
    expect(members, greaterThan(1));
    expect(members, lessThanOrEqualTo(SingboxConfig.kMaxAutoNodes),
        reason: 'capped for the iOS NE memory budget');
    // The rest of the config still targets the `proxy` tag.
    expect((cfg['route'] as Map)['final'], 'proxy');
    // ignore: avoid_print
    print('multi: ${nodes.length} nodes -> urltest of $members, '
        'json ${jsonEncode(cfg).length} bytes');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
