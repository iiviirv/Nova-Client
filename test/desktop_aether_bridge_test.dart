import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';

/// Desktop forwards into the Aether core, not at the WARP gateway.
///
/// An Aether node is not a server to dial: the core opens the tunnel and serves
/// it as a local SOCKS proxy. Desktop had no branch for that, so the node fell
/// through to the ordinary builder, which emits a socks outbound aimed at the
/// node's own address. That address is the gateway, which does not speak SOCKS.
///
/// A tester's Windows log is what this pins: every request failing with
/// "dial tcp 188.114.98.209:3476: i/o timeout", then "expected socks version 5,
/// got 72" when the gateway answered with HTTP (0x48 is 'H'). macOS did the
/// same. The core, the editor and the search all shipped on desktop; the one
/// missing piece was the thing that connects them.
void main() {
  // The identity path comes from the platform, which a test has none of.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '/tmp/nova-test-support',
    );
  });

  Map<String, dynamic> proxyOutbound(String cfg) {
    final Map<String, dynamic> m = jsonDecode(cfg) as Map<String, dynamic>;
    final List<dynamic> outs = (m['outbounds'] as List<dynamic>?) ?? <dynamic>[];
    return (outs.firstWhere((dynamic o) => (o as Map)['tag'] == 'proxy') as Map)
        .cast<String, dynamic>();
  }

  ProxyProfile aether(String uri) => ProxyProfile(
        id: 'a1',
        name: 'WARP',
        uri: uri,
        kind: ProxyKind.aether,
        updatedAt: DateTime.now(),
      );

  test('the socks outbound points at loopback, never at the gateway', () async {
    const String gateway = '188.114.98.209';
    final String cfg = await DesktopProxyController().buildConfigForTest(
        aether('aether://$gateway:3476?protocol=wg&scan=balanced&ip=v4#WARP'));

    final Map<String, dynamic> proxy = proxyOutbound(cfg);
    expect(proxy['type'], 'socks');
    expect(proxy['server'], '127.0.0.1',
        reason: 'the gateway does not speak SOCKS; the core does');
    expect(proxy['server'], isNot(gateway));
    expect(proxy['server_port'], isNot(3476));
    // A real loopback port, not a placeholder nothing will be listening on.
    expect(proxy['server_port'], isA<int>());
    expect(proxy['server_port'] as int, greaterThan(1024));
  });

  test('the WARP ranges are routed direct so the core can reach its edge',
      () async {
    final String cfg = await DesktopProxyController().buildConfigForTest(
        aether('aether://188.114.98.209:3476?protocol=wg&scan=balanced&ip=v4'));
    final Map<String, dynamic> m = jsonDecode(cfg) as Map<String, dynamic>;
    final List<dynamic> rules =
        ((m['route'] as Map)['rules'] as List<dynamic>);
    final Map<String, dynamic> first = (rules.first as Map).cast<String, dynamic>();
    expect(first['outbound'], 'direct',
        reason: 'in TUN mode the core dial is captured and fed back into the '
            'socks chain unless this rule comes first');
    expect((first['ip_cidr'] as List<dynamic>).join(','), contains('188.114.98.'));
  });

  test('a config with no gateway yet says so instead of building nothing',
      () async {
    await expectLater(
      DesktopProxyController()
          .buildConfigForTest(aether('aether://?protocol=wg&scan=balanced')),
      throwsA(isA<String>().having((String e) => e, 'message',
          contains('no gateway'))),
    );
  });
}
