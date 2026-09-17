import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_watchdog.dart';

/// A dead Aether core used to leave the tunnel device up and blackhole the
/// whole machine: no internet at all until the user disconnected Nova, at which
/// point hours of notifications arrived at once. These are the behaviours that
/// stop that happening again.
void main() {
  late DateTime clock;
  DateTime now() => clock;

  setUp(() => clock = DateTime(2026, 9, 17, 3, 0));

  test('a healthy tunnel is left alone', () async {
    int restarts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => true,
        restart: () async => restarts++,
        now: now);
    await w.check();
    await w.check();
    expect(restarts, 0);
  });

  test('a dead tunnel is restarted rather than left blackholing', () async {
    int restarts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => false,
        restart: () async => restarts++,
        now: now);
    await w.check();
    expect(restarts, 1);
  });

  // The check talking to a dead core can throw rather than answer. Reading that
  // as "fine" is how the tunnel stays dead.
  test('a check that throws counts as dead', () async {
    int restarts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => throw StateError('core is gone'),
        restart: () async => restarts++,
        now: now);
    await w.check();
    expect(restarts, 1);
  });

  test('restarts back off instead of spinning', () async {
    int restarts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => false,
        restart: () async => restarts++,
        now: now,
        firstBackoff: const Duration(seconds: 5),
        maxBackoff: const Duration(seconds: 60));

    await w.check();
    expect(restarts, 1);

    // Immediately again: still inside the backoff, so nothing happens.
    await w.check();
    expect(restarts, 1, reason: 'the watchdog spun instead of waiting');

    clock = clock.add(const Duration(seconds: 6));
    await w.check();
    expect(restarts, 2);

    // Backoff doubled to 10s, so 6 more seconds is not enough.
    clock = clock.add(const Duration(seconds: 6));
    await w.check();
    expect(restarts, 2, reason: 'the backoff did not grow');

    clock = clock.add(const Duration(seconds: 6));
    await w.check();
    expect(restarts, 3);
  });

  test('the backoff has a ceiling', () async {
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => false,
        restart: () async {},
        now: now,
        firstBackoff: const Duration(seconds: 5),
        maxBackoff: const Duration(seconds: 20));
    for (int i = 0; i < 8; i++) {
      await w.check();
      clock = clock.add(const Duration(seconds: 30));
    }
    // Thirty seconds must always be enough to get another attempt through.
    expect(w.consecutiveFailures, 8);
  });

  test('recovery clears the backoff and says so', () async {
    bool alive = false;
    final List<String> lines = <String>[];
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => alive,
        restart: () async {},
        now: now,
        log: (String m, {bool warn = false}) => lines.add(m));
    await w.check();
    expect(w.consecutiveFailures, 1);
    alive = true;
    await w.check();
    expect(w.consecutiveFailures, 0);
    expect(lines.last, contains('again'));

    // And a later death restarts immediately rather than serving out the old
    // backoff.
    alive = false;
    int restarts = 0;
    final AetherWatchdog w2 = AetherWatchdog(
        isServing: () async => alive,
        restart: () async => restarts++,
        now: now);
    await w2.check();
    expect(restarts, 1);
  });

  test('waking clears a backoff the user is waiting behind', () async {
    int restarts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => false,
        restart: () async => restarts++,
        now: now,
        firstBackoff: const Duration(seconds: 60));
    await w.check();
    expect(restarts, 1);
    await w.check();
    expect(restarts, 1);
    // The phone was unlocked, or the network changed. Sitting out the rest of a
    // minute while the user stares at a dead connection is the wrong answer.
    w.wake();
    await w.check();
    expect(restarts, 2);
  });

  test('a restart that throws does not stop later attempts', () async {
    int attempts = 0;
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async => false,
        restart: () async {
          attempts++;
          throw StateError('no route to host');
        },
        now: now,
        firstBackoff: const Duration(seconds: 5));
    await w.check();
    clock = clock.add(const Duration(seconds: 10));
    await w.check();
    expect(attempts, 2);
  });

  // A timer firing again while the previous pass is still waiting on a slow
  // core. Without the guard this starts a second restart on top of the first.
  test('overlapping checks do not start two restarts', () async {
    int restarts = 0;
    final Completer<void> hold = Completer<void>();
    final AetherWatchdog w = AetherWatchdog(
        isServing: () async {
          await hold.future;
          return false;
        },
        restart: () async => restarts++,
        now: now);
    final Future<void> first = w.check();
    final Future<void> second = w.check();
    expect(w.busy, isTrue);
    hold.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(restarts, 1, reason: 'two restarts ran at once');
  });
}
