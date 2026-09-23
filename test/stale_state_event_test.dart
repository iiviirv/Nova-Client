import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// Field log, 2026-09-23, iPhone: connecting straight after a disconnect put
/// the app back to `disconnected` two milliseconds later, while the gateway
/// search it had just started was still running.
///
///     10:50:53.421  State: disconnected      <- previous session finishing
///     10:50:53.422  Connecting with "MASQUE"
///     10:50:53.422  aether search: start
///     10:50:53.424  State: disconnected      <- stale, lands on the new connect
///
/// The host was reporting the end of the session being torn down, but the
/// controller applied it to the connect in flight. connect() then discards its
/// own result, because it checks it is still `connecting` before sending start.
/// From the outside that looks like a protocol that never connects.
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
        updatedAt: DateTime(2026, 9, 23),
      );

  late List<String> calls;

  SingboxProxyController controller() {
    calls = <String>[];
    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'coreFeatures') return <String, Object>{};
      return null;
    });
    return SingboxProxyController(
      control: control,
      events: events,
      features: CoreFeatures(control: control),
    );
  }

  /// Delivers one event the way the platform host would.
  Future<void> emitState(String value) async {
    await messenger.handlePlatformMessage(
      'nova.proxy/events',
      const StandardMethodCodec()
          .encodeSuccessEnvelope(<String, Object?>{'type': 'state', 'value': value}),
      (_) {},
    );
  }

  tearDown(() => messenger.setMockMethodCallHandler(control, null));

  test('a disconnected that arrives before start belongs to the old session',
      () async {
    final SingboxProxyController c = controller();
    final Completer<String> slowBody = Completer<String>();
    c.subFetcherProvider = () => (Uri _) => slowBody.future;
    c.selectProfile(sub('a', 'https://a.example/sub'));

    final Future<void> connecting = c.connect();
    expect(c.state, ProxyConnectionState.connecting);

    // The previous session finishes tearing down, two milliseconds late.
    await emitState('disconnected');
    expect(c.state, ProxyConnectionState.connecting,
        reason: 'the stale event must not overwrite the connect in flight');

    slowBody.complete(base64.encode(utf8.encode(link('a.example', 'A'))));
    await connecting;
    expect(calls, contains('start'),
        reason: 'the connect must survive and reach the core');
  });

  test('a disconnected after start is real and is honoured', () async {
    final SingboxProxyController c = controller();
    c.subFetcherProvider = () =>
        (Uri _) async => base64.encode(utf8.encode(link('a.example', 'A')));
    c.selectProfile(sub('a', 'https://a.example/sub'));

    await c.connect();
    expect(calls, contains('start'));

    // The core really did go down this time.
    await emitState('disconnected');
    expect(c.state, ProxyConnectionState.disconnected,
        reason: 'once start has gone out, the host is describing this session');
  });

  test('connecting is still reported normally while a connect is in flight',
      () async {
    final SingboxProxyController c = controller();
    final Completer<String> slowBody = Completer<String>();
    c.subFetcherProvider = () => (Uri _) => slowBody.future;
    c.selectProfile(sub('a', 'https://a.example/sub'));

    final Future<void> connecting = c.connect();
    // Only terminal states are suspect; anything else passes through.
    await emitState('connected');
    expect(c.state, ProxyConnectionState.connected);

    slowBody.complete(base64.encode(utf8.encode(link('a.example', 'A'))));
    await connecting;
  });
}
