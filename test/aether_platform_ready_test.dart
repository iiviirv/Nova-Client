import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_platform_ready.dart';

void main() {
  test('a queued start waits until the native core is connected', () async {
    final ready = Completer<String?>();
    var calls = 0;
    var started = false;
    final wait = waitForAetherPlatform(() async {
      if (++calls == 1) return 'connecting';
      return ready.future;
    }, interval: Duration.zero).then((_) => started = true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(started, isFalse);
    ready.complete('connected');
    await wait;
    expect(started, isTrue);
    expect(calls, 2);
  });

  test('a stopped service cannot start an Aether socket', () async {
    for (final state in ['error', 'disconnected', 'disconnecting']) {
      await expectLater(waitForAetherPlatform(() async => state),
          throwsStateError);
    }
  });

  test('a native status call that never answers is bounded', () async {
    await expectLater(waitForAetherPlatform(() => Completer<String?>().future,
        timeout: const Duration(milliseconds: 20)), throwsA(isA<TimeoutException>()));
  });

  test('an unavailable status channel never counts as ready', () async {
    await expectLater(waitForAetherPlatform(() async => throw StateError('unavailable')),
        throwsStateError);
  });
}
