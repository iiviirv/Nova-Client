import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// The mobile half of "test all servers through the core": Dart hands the host a
/// measuring config, the host starts a core, and Dart then drives the run itself
/// over that core's Clash API. Here the "core" is a scripted HTTP server bound
/// to the very port the controller chose, so the whole path is exercised.
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

  HttpServer? fakeCore;

  setUp(() {
    SingboxProxyController.measureForTest = true;
    // flutter_test installs HttpOverrides that answer every request with 400;
    // this test talks to a real loopback server it starts itself.
    HttpOverrides.global = null;
  });
  tearDown(() async {
    SingboxProxyController.measureForTest = false;
    messenger.setMockMethodCallHandler(control, null);
    await fakeCore?.close(force: true);
    fakeCore = null;
  });

  /// Stands a fake measuring core up on whichever loopback port the config the
  /// controller sent asked for, answering [script] (tag -> successive delays,
  /// null = "no response") the way sing-box's Clash API would.
  Future<void> hostFakeCore(
    Map<String, dynamic> config,
    Map<String, List<int?>> script,
    List<String> seen,
  ) async {
    final String controller = ((config['experimental'] as Map)['clash_api']
        as Map)['external_controller'] as String;
    final int port = int.parse(controller.split(':').last);
    final Map<String, int> calls = <String, int>{};
    fakeCore = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    fakeCore!.listen((HttpRequest req) async {
      final List<String> p = req.uri.pathSegments;
      if (p.length == 1 && p.first == 'version') {
        req.response.write('{"version":"fake"}');
      } else if (p.length == 3 && p[0] == 'proxies' && p[2] == 'delay') {
        final String tag = p[1];
        seen.add(tag);
        final List<int?>? s = script[tag];
        final int n = calls.update(tag, (int v) => v + 1, ifAbsent: () => 1) - 1;
        final int? d =
            s == null ? null : s[n < s.length ? n : s.length - 1];
        if (d == null) {
          req.response.statusCode = 503;
        } else {
          req.response.write(jsonEncode(<String, int>{'delay': d}));
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  test('warm numbers land on coreHealth; a silent node is "no response"',
      () async {
    Map<String, dynamic>? sentConfig;
    Map<Object?, Object?>? sentArgs;
    final List<String> seen = <String>[];
    bool stopped = false;
    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      if (call.method == 'measure') {
        sentArgs = (call.arguments as Map).cast<Object?, Object?>();
        sentConfig = jsonDecode(call.arguments['configJson'] as String)
            as Map<String, dynamic>;
        await hostFakeCore(sentConfig!, <String, List<int?>>{
          // Cold 420, warm 180: the warm one is the honest figure.
          'node-0': <int?>[420, 180],
          'node-2': <int?>[500, 420],
        }, seen);
      }
      if (call.method == 'measureCancel') stopped = true;
      return null;
    });
    final SingboxProxyController c = SingboxProxyController(
        control: control,
        events: events,
        features: CoreFeatures(control: control));
    final List<ProxyNode> n = nodes(3);
    final String? problem = await c.measureNodes(n);
    expect(problem, isNull);

    // What the host was handed: a measuring config (mixed inbound, no tun, no
    // rule-sets to ship).
    expect((sentConfig!['inbounds'] as List<dynamic>).single['type'], 'mixed');
    expect(sentArgs!.keys, isNot(contains('ruleSets')),
        reason: 'a measuring core has no rule-sets to carry any more');

    // What the list sees.
    final CoreNodeHealth h = c.coreHealth.value;
    expect(h.delayFor(n[0]), 180, reason: 'the warm dial, not the cold one');
    expect(h.delayFor(n[2]), 420);
    expect(h.delayFor(n[1]), isNull);
    expect(h.wasTested(n[1]), isTrue, reason: 'tried, no answer: "no response"');
    // The live node was warmed and then timed. The silent one got its
    // immediate retry and then one more after the pool drained, which is the
    // pass that recovers servers a saturated first run writes off.
    expect(seen.where((String t) => t == 'node-1'), hasLength(3));
    expect(seen.where((String t) => t == 'node-0'), hasLength(2));
    expect(c.measuring.value, isFalse);
    expect(stopped, isTrue, reason: 'the measuring core is always torn down');
  });

  test('refuses while the tunnel is up', () async {
    messenger.setMockMethodCallHandler(control, (MethodCall call) async => null);
    final SingboxProxyController c = SingboxProxyController(
        control: control,
        events: events,
        features: CoreFeatures(control: control));
    c.debugSetStateForTest(ProxyConnectionState.connected);
    final String? problem = await c.measureNodes(nodes(2));
    expect(problem, contains('Disconnect first'));
  });
}
