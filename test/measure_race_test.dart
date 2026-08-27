import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

/// Field report: after several lightning tests, or a few server switches, the
/// expensive protocols (Reality, Hysteria2, SS2022) started reading "no
/// response", raising the timeout hid it, and a freshly opened app was always
/// fast.
///
/// The cause was re-entry. `cancelMeasure` clears the `measuring` flag at once,
/// but the run it cancelled is still inside dials that can take up to a minute
/// to give up, and that flag was the only guard. So cancelling and immediately
/// re-testing started a SECOND measuring core on top of a first that was still
/// dialling. Two cores competing is not evenly unfair: the protocols that pay a
/// real handshake to open a session are the ones that run out of time.
///
/// This pins that a second run cannot begin until the first has finished.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nova.proxy/control');
  const EventChannel events = EventChannel('nova.proxy/events');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  ProxyNode node(String host) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: host,
        port: 443,
        tag: host,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        network: 'ws',
        wsPath: '/ws',
      );

  setUp(() => SingboxProxyController.measureForTest = true);
  tearDown(() {
    SingboxProxyController.measureForTest = false;
    messenger.setMockMethodCallHandler(control, null);
  });

  test('a second run cannot start while the first is still unwinding', () async {
    int measureStarts = 0;
    int concurrent = 0;
    int maxConcurrent = 0;
    final Completer<void> holdFirst = Completer<void>();

    messenger.setMockMethodCallHandler(control, (MethodCall call) async {
      switch (call.method) {
        case 'measure':
          measureStarts++;
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          // The first run's core stays "up" until we let it go, standing in for
          // workers still waiting out their dials.
          if (measureStarts == 1) await holdFirst.future;
          return null;
        case 'measureCancel':
          if (concurrent > 0) concurrent--;
          return null;
        default:
          return null;
      }
    });

    final SingboxProxyController c = SingboxProxyController(
      control: control,
      events: events,
      features: CoreFeatures(control: control),
    );
    addTearDown(c.dispose);

    final Future<String?> first = c.measureNodes(<ProxyNode>[node('a.example')]);
    await Future<void>.delayed(Duration.zero);
    expect(c.measuring.value, isTrue);

    // The user cancels, which clears the flag immediately, then asks again
    // while the first run is still inside its dial.
    await c.cancelMeasure();
    expect(c.measuring.value, isFalse, reason: 'cancel clears the flag at once');
    final Future<String?> second =
        c.measureNodes(<ProxyNode>[node('b.example')]);

    // The second run must be waiting, not running a core of its own.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(maxConcurrent, 1,
        reason: 'two measuring cores were up at once, which is the bug');

    holdFirst.complete();
    await first;
    await second;
    expect(maxConcurrent, 1);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
