import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/measure_runner.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';

/// The rule the free-list search stops on. Thirty answering servers is not a
/// usable list if all thirty take two seconds, so the search keeps going into
/// the pool until enough of them are fast.
bool _done(Map<String, int> delays) {
  if (delays.length < kFreeListTarget) return false;
  int fast = 0;
  for (final int ms in delays.values) {
    if (ms < kFreeListFastMs) fast++;
  }
  return fast >= kFreeListFastMin;
}

Map<String, int> _delays({required int slow, required int fast}) => <String, int>{
      for (int i = 0; i < slow; i++) 'slow$i': 1500,
      for (int i = 0; i < fast; i++) 'fast$i': 120,
    };

void main() {
  test('does not stop before the target is reached', () {
    expect(_done(_delays(slow: 0, fast: kFreeListTarget - 1)), isFalse);
  });

  test('stops at the target when enough of them are fast', () {
    final Map<String, int> d = _delays(
      slow: kFreeListTarget - kFreeListFastMin,
      fast: kFreeListFastMin,
    );
    expect(d.length, kFreeListTarget);
    expect(_done(d), isTrue);
  });

  test('keeps searching past the target when the fast ones are missing', () {
    // Thirty servers, but only four under 300ms: the exception Vahid asked for.
    final Map<String, int> d = _delays(
      slow: kFreeListTarget - (kFreeListFastMin - 1),
      fast: kFreeListFastMin - 1,
    );
    expect(d.length, kFreeListTarget);
    expect(_done(d), isFalse);
  });

  test('stops once the fifth fast one turns up, however long the list got', () {
    final Map<String, int> d = _delays(slow: 200, fast: kFreeListFastMin);
    expect(_done(d), isTrue);
  });

  test('the runner honours a stop predicate', () async {
    // Proves the predicate is actually wired into the run, not just defined.
    int served = 0;
    final Map<String, int> found = await MeasureRunner.run(
      api: Uri.parse('http://127.0.0.1:1/'),
      tagKeys: <String, String>{
        for (int i = 0; i < 50; i++) 'node-$i': 'key-$i',
      },
      url: 'HTTP://example.invalid/',
      timeoutSec: 1,
      concurrency: 1,
      stopWhen: (Map<String, int> d) {
        served++;
        return true; // stop immediately
      },
    );
    expect(served, greaterThan(0));
    expect(found, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
