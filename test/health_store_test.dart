import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/health_store.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A full sweep takes one to two minutes. It used to live only in memory, so
/// anything that tore the app down threw it away: on Android, leaving with the
/// back button rather than home was enough, and the next open re-tested from
/// nothing.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const CoreNodeHealth h = CoreNodeHealth(
    delayMsByKey: <String, int>{'a': 40, 'b': 120},
    testedKeys: <String>{'a', 'b', 'c'},
  );

  test('results come back after a restart', () async {
    await HealthStore.save('p1', h);
    final CoreNodeHealth? back = await HealthStore.load('p1');
    expect(back, isNotNull);
    expect(back!.delayMsByKey, <String, int>{'a': 40, 'b': 120});
    expect(back.testedKeys, <String>{'a', 'b', 'c'},
        reason: 'a server tried and silent must stay "no response", not reset '
            'to untested');
  });

  test('a profile with nothing saved returns null', () async {
    expect(await HealthStore.load('never'), isNull);
  });

  test('refresh clears them', () async {
    await HealthStore.save('p2', h);
    await HealthStore.clear('p2');
    expect(await HealthStore.load('p2'), isNull);
  });

  test('profiles do not share results', () async {
    await HealthStore.save('a', h);
    expect(await HealthStore.load('b'), isNull);
  });

  test('stale results are dropped rather than shown as current', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.health.old': '{"at":1,"delays":{"a":40},"tested":["a"]}',
    });
    expect(await HealthStore.load('old'), isNull,
        reason: 'a latency from last week describes a server that may be gone');
  });
}
