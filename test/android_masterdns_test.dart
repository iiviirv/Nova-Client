import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// MasterDNS on a phone, driven through the real connect path with the
/// platform channel faked and a stand-in engine.
///
/// The part that matters most is where the engine's traffic goes. Its traffic
/// IS DNS, and the tunnel hijacks DNS, so the engine has to be outside the
/// tunnel. That is done by taking this app out of its own tunnel at the Android
/// level, and these tests pin exactly how, including the case Android refuses:
/// a config that names both an allow list and a deny list.
const String self = 'online.novaproxy.nova_client';

/// Stands in for the engine: reads its port from the config it was handed and
/// listens there, which is the signal the real engine gives once it has a
/// working path. Records its arguments so the test can check what it was given.
const String listeningEngine = r'''#!/bin/sh
conf="$2"
echo "$@" > "$(dirname "$0")/args.txt"
# exec keeps this PID, and replaces the command line, so the PID is the only
# reliable handle on the process from outside.
echo $$ > "$(dirname "$0")/pid.txt"
port=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['LISTEN_PORT'])" "$conf")
exec python3 -c "
import socket,sys
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',int(sys.argv[1])));s.listen(8)
while True:
    c,_=s.accept();c.close()
" "$port"
''';

/// Stands in for an engine handed a config it cannot use: it exits at once.
const String refusingEngine = '#!/bin/sh\necho "ENCRYPTION_KEY is required" >&2\nexit 1\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel control = MethodChannel('nova.proxy/control');
  const EventChannel events = EventChannel('nova.proxy/events');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory libDir;
  late Directory support;
  late List<String> calls;
  Map<String, dynamic>? started;

  setUp(() {
    libDir = Directory.systemTemp.createTempSync('nova-lib-');
    support = Directory.systemTemp.createTempSync('nova-support-');
    calls = <String>[];
    started = null;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => support.path,
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(control, null);
    // Anything a test left running.
    final File pid = File('${libDir.path}/pid.txt');
    if (pid.existsSync()) {
      await Process.run('kill', <String>['-9', pid.readAsStringSync().trim()]);
    }
    try {
      libDir.deleteSync(recursive: true);
      support.deleteSync(recursive: true);
    } catch (_) {}
  });

  void installEngine(String script) {
    final File f = File('${libDir.path}/libmasterdns.so')
      ..writeAsStringSync(script);
    Process.runSync('chmod', <String>['+x', f.path]);
  }

  SingboxProxyController controller({
    int? proxyPort,
    List<String> include = const <String>[],
    List<String> exclude = const <String>[],
  }) {
    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'nativeLibraryDir') return libDir.path;
      if (call.method == 'coreFeatures') return <String, Object>{};
      if (call.method == 'start') {
        started = jsonDecode(call.arguments['configJson'] as String)
            as Map<String, dynamic>;
      }
      return null;
    });
    final SingboxProxyController c = SingboxProxyController(
      control: control,
      events: events,
      features: CoreFeatures(control: control),
    )
      ..proxyPortProvider = (() => proxyPort)
      ..routeOptionsProvider = (() => SingboxRouteOptions(
            includePackages: include,
            excludePackages: exclude,
          ));
    c.selectProfile(ProxyProfile(
      id: 'm',
      name: 'DNS',
      kind: ProxyKind.masterdns,
      uri: const MasterDnsConfig(
        domains: <String>['t.example.test'],
        key: '0123456789abcdef0123456789abcdef',
        resolvers: <String>['8.8.8.8', '1.1.1.1'],
      ).toLink(),
      updatedAt: DateTime(2026, 9, 17),
    ));
    return c;
  }

  Map<String, dynamic> tun() => ((started!['inbounds'] as List<dynamic>)
          .firstWhere((dynamic i) => (i as Map)['type'] == 'tun') as Map)
      .cast<String, dynamic>();

  bool hasLoopbackInbound() => (started!['inbounds'] as List<dynamic>)
      .any((dynamic i) => (i as Map)['type'] == 'mixed');

  for (final bool proxyMode in <bool>[false, true]) {
    test('LAN authentication keeps app probes private, proxyMode=$proxyMode', () async {
      installEngine(listeningEngine);
      final c = controller(proxyPort: proxyMode ? 3080 : null)
        ..sharedProxyPortProvider = (() => 3080)
        ..proxyShareProvider = () => (onLan: true, user: 'nova', pass: 'test');
      await c.connect();
      expect(started, isNotNull, reason: '${c.lastError}');
      final inbounds = (started!['inbounds'] as List).cast<Map>();
      expect(inbounds.where((i) => i['type'] == 'tun').length, proxyMode ? 0 : 1);
      final shared = inbounds.singleWhere((i) => i['listen'] == '0.0.0.0');
      expect(shared['listen_port'], 3080);
      expect(shared['users'], [{'username': 'nova', 'password': 'test'}]);
      final internal = inbounds.singleWhere((i) => i['tag'] == 'nova-private');
      expect(internal['listen'], '127.0.0.1');
      expect(internal.containsKey('users'), isFalse);
      expect(internal['listen_port'], isNot(3080));
      c.debugSetStateForTest(ProxyConnectionState.connected);
      expect(c.proxyUri, 'PROXY 127.0.0.1:${internal['listen_port']}');
      await c.disconnect();
    });
  }

  test('full-device mode takes this app out of its own tunnel', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller();
    await c.connect();
    expect(started, isNotNull, reason: 'lastError=${c.lastError}');
    expect(tun()['exclude_package'], contains(self),
        reason: 'the engine runs as this app; inside the tunnel its DNS '
            'would be hijacked and the tunnel could never form');
    expect(tun().containsKey('include_package'), isFalse);
    expect(hasLoopbackInbound(), isTrue,
        reason: 'the app still needs a way into its own tunnel');
    await c.disconnect();
  });

  test('the dashboard is pointed at the loopback port, not the real line',
      () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller();
    await c.connect();
    c.debugSetStateForTest(ProxyConnectionState.connected);
    expect(c.localProxyPort, isNotNull,
        reason: 'otherwise the dashboard reads the real address as the exit');
    await c.disconnect();
  });

  // Android refuses a config naming both lists.
  test('an allow list is kept as an allow list, without this app', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c =
        controller(include: <String>['org.telegram.messenger', self]);
    await c.connect();
    expect(tun()['include_package'], <String>['org.telegram.messenger']);
    expect(tun().containsKey('exclude_package'), isFalse,
        reason: 'Android rejects a config with both lists');
    await c.disconnect();
  });

  test('an allow list of only this app becomes a deny list', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller(include: <String>[self]);
    await c.connect();
    expect(tun().containsKey('include_package'), isFalse);
    expect(tun()['exclude_package'], contains(self));
    await c.disconnect();
  });

  test('an existing deny list is extended, not replaced', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c =
        controller(exclude: <String>['com.bank.app']);
    await c.connect();
    expect(tun()['exclude_package'],
        containsAll(<String>['com.bank.app', self]));
    await c.disconnect();
  });

  test('proxy mode leaves the app lists alone, there is no tunnel', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller(proxyPort: 2080);
    await c.connect();
    expect(started, isNotNull, reason: 'lastError=${c.lastError}');
    final bool anyTun = (started!['inbounds'] as List<dynamic>)
        .any((dynamic i) => (i as Map)['type'] == 'tun');
    expect(anyTun, isFalse);
    await c.disconnect();
  });

  test('the engine is given a config file, and the file does not stay',
      () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller();
    await c.connect();
    final String args = File('${libDir.path}/args.txt').readAsStringSync();
    expect(args, startsWith('-json '),
        reason: 'on the command line the key would be in the process list');
    expect(args, contains('-resolvers'));
    expect(File('${support.path}/nova-masterdns.json').existsSync(), isFalse,
        reason: 'the key was left on disk');
    expect(
        File('${support.path}/nova-masterdns-resolvers.txt').readAsStringSync(),
        '8.8.8.8\n1.1.1.1\n');
    await c.disconnect();
  });

  test('an engine that refuses its config fails the connect at once',
      () async {
    installEngine(refusingEngine);
    final SingboxProxyController c = controller();
    final Stopwatch clock = Stopwatch()..start();
    await c.connect();
    expect(c.state, ProxyConnectionState.error);
    expect(c.lastError, contains('refused'));
    expect(calls, isNot(contains('start')),
        reason: 'no tunnel should come up over an engine that is not there');
    expect(clock.elapsed, lessThan(const Duration(seconds: 15)),
        reason: 'it should not wait out the whole budget');
  });

  test('a build without the engine says so', () async {
    final SingboxProxyController c = controller();
    await c.connect();
    expect(c.state, ProxyConnectionState.error);
    expect(c.lastError, contains('no MasterDNS engine'));
    expect(calls, isNot(contains('start')));
  });

  test('disconnect stops the engine, which never exits by itself', () async {
    installEngine(listeningEngine);
    final SingboxProxyController c = controller();
    await c.connect();
    final String pid =
        File('${libDir.path}/pid.txt').readAsStringSync().trim();
    Future<bool> running() async =>
        (await Process.run('kill', <String>['-0', pid])).exitCode == 0;

    expect(await running(), isTrue);
    await c.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await running(), isFalse);
  });
}
