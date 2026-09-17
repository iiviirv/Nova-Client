import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';

/// Desktop forwards into the MasterDNS engine, and in full-device mode keeps
/// the engine's own traffic out of the DNS hijack.
///
/// That second part is specific to what this tunnel is made of. Its traffic is
/// DNS, and the shared route hijacks every DNS packet into the core's resolver
/// as its second rule. Without an exception placed ahead of that, sing-box would
/// answer the engine's tunnel queries itself and the tunnel could never form.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // The platform creates this directory in a real app; a test has to.
    Directory('/tmp/nova-test-support').createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '/tmp/nova-test-support',
    );
  });

  String link({String key = '0123456789abcdef0123456789abcdef'}) =>
      MasterDnsConfig(
        domains: const <String>['t.example.test'],
        key: key,
        resolvers: const <String>['8.8.8.8', '1.1.1.1'],
        name: 'DNS',
      ).toLink();

  ProxyProfile profile(String uri) => ProxyProfile(
        id: 'm1',
        name: 'DNS',
        uri: uri,
        kind: ProxyKind.masterdns,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> cfgOf(String s) => jsonDecode(s) as Map<String, dynamic>;

  List<dynamic> rulesOf(Map<String, dynamic> c) =>
      (c['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;

  test('the core forwards into the engine on loopback', () async {
    final Map<String, dynamic> c = cfgOf(
        await DesktopProxyController().buildConfigForTest(profile(link())));
    final Map<String, dynamic> proxy = ((c['outbounds'] as List<dynamic>)
            .firstWhere((dynamic o) => (o as Map)['tag'] == 'proxy') as Map)
        .cast<String, dynamic>();
    expect(proxy['type'], 'socks');
    expect(proxy['server'], '127.0.0.1');
    expect(proxy['server'], isNot('t.example.test'),
        reason: 'the domain is not a server anything dials');
    expect(proxy['server_port'] as int, greaterThan(1024));
  });

  test('proxy mode adds no process exception, there is nothing to loop', () async {
    final Map<String, dynamic> c = cfgOf(
        await DesktopProxyController().buildConfigForTest(profile(link())));
    expect(rulesOf(c).any((dynamic r) => (r as Map).containsKey('process_path')),
        isFalse);
  });

  test('full-device mode lets the engine out ahead of the DNS hijack', () async {
    final DesktopProxyController d = DesktopProxyController()
      ..tunModeProvider = () => true;
    final Map<String, dynamic> c =
        cfgOf(await d.buildConfigForTest(profile(link())));
    final List<dynamic> rules = rulesOf(c);
    final int exception = rules.indexWhere(
        (dynamic r) => (r as Map).containsKey('process_path'));
    final int hijack = rules.indexWhere(
        (dynamic r) => (r as Map)['action'] == 'hijack-dns');
    // Strict on purpose. The engine binaries ship in assets/bin for every host
    // these tests run on, so a missing exception is a bug, not an environment.
    // An earlier version returned early here, which let a build that never
    // added the exception at all pass this test.
    expect(exception, greaterThanOrEqualTo(0),
        reason: 'full-device mode must exclude the engine');
    expect(hijack, greaterThanOrEqualTo(0));
    expect(exception, lessThan(hijack),
        reason: 'placed after the hijack, it would never be reached');
    expect((rules[exception] as Map)['outbound'], 'direct');
    expect((c['route'] as Map)['find_process'], isTrue);
  });

  // The engine carries UDP only to port 53, so HTTP/3 would hang rather than
  // fail. Blocking it is what makes apps fall back to TCP.
  test('QUIC is blocked, because the tunnel cannot carry it', () async {
    final Map<String, dynamic> c = cfgOf(
        await DesktopProxyController().buildConfigForTest(profile(link())));
    final String route = jsonEncode(c['route']);
    expect(route, contains('quic'));
  });

  test('a config missing its key fails with something a person can act on',
      () async {
    await expectLater(
      DesktopProxyController().buildConfigForTest(profile(link(key: ''))),
      throwsA(predicate((Object e) =>
          '$e'.contains('encryption key') && '$e'.contains('Open it'))),
    );
  });

  test('something that is not a MasterDNS link is refused plainly', () async {
    await expectLater(
      DesktopProxyController()
          .buildConfigForTest(profile('masterdns://not-base64-at-all!!')),
      throwsA(anything),
    );
  });
}
