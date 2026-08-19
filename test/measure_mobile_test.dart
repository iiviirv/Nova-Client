import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// The mobile half of "test all servers through the core": the Dart side hands
/// the host a measuring config plus the node-i tags, and turns the host's
/// tag -> delay answer into coreHealth (a missing tag is "no response").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nova.proxy/control');
  const EventChannel events = EventChannel('nova.proxy/events');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<ProxyNode> nodes(int n) => <ProxyNode>[
        for (int i = 0; i < n; i++)
          parseShareLink('vless://00000000-0000-0000-0000-00000000000$i'
              '@h$i.example.net:443?type=ws&security=tls&sni=h$i.example.net'
              '&path=%2Fws#Node $i')!,
      ];

  setUp(() => SingboxProxyController.measureForTest = true);
  tearDown(() {
    SingboxProxyController.measureForTest = false;
    messenger.setMockMethodCallHandler(control, null);
  });

  test('publishes the host\'s delays on coreHealth; unanswered = tested only',
      () async {
    Map<String, dynamic>? sentConfig;
    List<dynamic>? sentTags;
    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      if (call.method == 'measure') {
        sentConfig = jsonDecode(call.arguments['configJson'] as String)
            as Map<String, dynamic>;
        sentTags = call.arguments['tags'] as List<dynamic>;
        // node-1 never answered.
        return <String, int>{'node-0': 180, 'node-2': 420};
      }
      return null;
    });
    final SingboxProxyController c = SingboxProxyController(
        control: control, events: events, features: CoreFeatures(control: control));
    final List<ProxyNode> n = nodes(3);
    final String? problem = await c.measureNodes(n);
    expect(problem, isNull);
    // What the host was handed: a measuring config (mixed inbound, no tun).
    expect((sentConfig!['inbounds'] as List<dynamic>).single['type'], 'mixed');
    expect(sentTags, <String>['node-0', 'node-1', 'node-2']);
    // What the list sees.
    final CoreNodeHealth h = c.coreHealth.value;
    expect(h.delayFor(n[0]), 180);
    expect(h.delayFor(n[2]), 420);
    expect(h.delayFor(n[1]), isNull);
    expect(h.wasTested(n[1]), isTrue, reason: 'tried, no answer: "no response"');
    expect(c.measuring.value, isFalse);
  });

  test('refuses while the tunnel is up', () async {
    messenger.setMockMethodCallHandler(control, (MethodCall call) async => null);
    final SingboxProxyController c = SingboxProxyController(
        control: control, events: events, features: CoreFeatures(control: control));
    c.debugSetStateForTest(ProxyConnectionState.connected);
    final String? problem = await c.measureNodes(nodes(2));
    expect(problem, contains('Disconnect first'));
  });
}
