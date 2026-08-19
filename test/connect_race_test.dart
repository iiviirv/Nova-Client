import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// Field report: after switching servers quickly a few times (and toggling the
/// SNI bypass, which reconnects) the app sat on "connecting" and, on Android,
/// the phone was left with a VPN that carried nothing until a force close.
///
/// Two halves fix that. The Android service now runs every start and stop on
/// one worker (NovaVpnService.kt, not testable here). This file pins the Dart
/// half: a connect() that was overtaken while it resolved its config never
/// sends `start`, overlapping reconnect()s coalesce, and a stop the host never
/// answers cannot leave the UI on "disconnecting" forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nova.proxy/control');
  const EventChannel events = EventChannel('nova.proxy/events');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String link(String host, String name) =>
      'vless://00000000-0000-0000-0000-000000000000@$host:443'
      '?type=ws&security=tls&sni=$host&path=%2Fws#$name';

  ProxyProfile sub(String id, String url) => ProxyProfile(
        id: id,
        name: id,
        kind: ProxyKind.subscription,
        uri: '',
        subscriptionUrl: url,
        updatedAt: DateTime(2026, 8, 19),
      );

  List<String> calls = <String>[];
  List<String> startedServers = <String>[];

  SingboxProxyController controller() {
    calls = <String>[];
    startedServers = <String>[];
    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'start') {
        final Map<String, dynamic> cfg =
            jsonDecode(call.arguments['configJson'] as String)
                as Map<String, dynamic>;
        for (final dynamic o in cfg['outbounds'] as List<dynamic>) {
          if (o is Map && o['server'] is String) {
            startedServers.add(o['server'] as String);
          }
        }
      }
      if (call.method == 'coreFeatures') return <String, Object>{};
      return null;
    });
    return SingboxProxyController(
      control: control,
      events: events,
      features: CoreFeatures(control: control),
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(control, null));

  test('a connect overtaken by a disconnect never sends start', () async {
    final SingboxProxyController c = controller();
    final Completer<String> slowBody = Completer<String>();
    c.subFetcherProvider = () => (Uri _) => slowBody.future;
    c.selectProfile(sub('a', 'https://a.example/sub'));

    final Future<void> first = c.connect();
    expect(c.state, ProxyConnectionState.connecting);
    // The user gives up while the subscription is still loading.
    await c.disconnect();
    // Now the subscription answers.
    slowBody.complete(base64.encode(utf8.encode(link('a.example', 'A'))));
    await first;

    expect(calls.where((m) => m == 'start'), isEmpty,
        reason: 'the stale connect must not start a tunnel after the stop');
    expect(calls, contains('stop'));
  });

  test('two overlapping connects start only the newer profile', () async {
    final SingboxProxyController c = controller();
    final Completer<String> slowA = Completer<String>();
    final Map<String, Future<String> Function()> bodies =
        <String, Future<String> Function()>{
      'a.example': () => slowA.future,
      'b.example': () async =>
          base64.encode(utf8.encode(link('b.example', 'B'))),
    };
    c.subFetcherProvider = () => (Uri u) => bodies[u.host]!();

    c.selectProfile(sub('a', 'https://a.example/sub'));
    final Future<void> first = c.connect();
    // Switches to B while A is still resolving.
    c.selectProfile(sub('b', 'https://b.example/sub'));
    final Future<void> second = c.connect();
    await second;
    slowA.complete(base64.encode(utf8.encode(link('a.example', 'A'))));
    await first;

    expect(startedServers, <String>['b.example'],
        reason: 'only the newest request may reach the core');
  });

  test('overlapping reconnects coalesce into one stop/start chain', () async {
    final SingboxProxyController c = controller();
    c.subFetcherProvider =
        () => (Uri u) async => base64.encode(utf8.encode(link(u.host, 'X')));
    c.selectProfile(sub('a', 'https://a.example/sub'));
    await c.connect();
    expect(calls.where((m) => m == 'start'), hasLength(1));

    // The host never answers with state events in this harness, so each stop
    // waits for the 8s reconnect timeout; three reconnects fired together must
    // still produce an orderly chain, not three interleaved ones. fakeAsync
    // cannot drive the platform-channel futures, so this runs in real time.
    final Future<void> r1 = c.reconnect();
    final Future<void> r2 = c.reconnect();
    final Future<void> r3 = c.reconnect();
    await Future.wait<void>(<Future<void>>[r1, r2, r3]);

    // One in-flight round plus one coalesced extra round: two stops, two
    // starts, never three.
    expect(calls.where((m) => m == 'stop'), hasLength(2));
    expect(calls.where((m) => m == 'start'), hasLength(3));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a stop the host never acknowledges settles to disconnected', () {
    fakeAsync((FakeAsync async) {
      final SingboxProxyController c = controller();
      c.disconnect();
      async.flushMicrotasks();
      expect(c.state, ProxyConnectionState.disconnecting);
      async.elapse(const Duration(seconds: 7));
      expect(c.state, ProxyConnectionState.disconnected);
    });
  });
}
