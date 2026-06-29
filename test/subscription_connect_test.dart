import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
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
}
