import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/update/update_checker.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _release(String tag) => jsonEncode(<String, dynamic>{'tag_name': tag});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    novaUpdateTag.value = null;
  });

  test('a newer release tag raises the banner', () async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await checkForNovaUpdate(prefs,
        force: true, fetch: (_) async => _release('v9.9.9-beta'));
    expect(novaUpdateTag.value, 'v9.9.9-beta');
  });

  test('the same tag this build shipped as raises nothing', () async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await checkForNovaUpdate(prefs,
        force: true, fetch: (_) async => _release(kNovaReleaseTag));
    expect(novaUpdateTag.value, isNull);
  });

  test('a blocked/failed check never throws and leaves state untouched',
      () async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await checkForNovaUpdate(prefs,
        force: true, fetch: (_) async => throw Exception('blocked'));
    expect(novaUpdateTag.value, isNull);
  });

  test('the once-a-day gate skips a second check within 24h', () async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int calls = 0;
    Future<String> fetch(Uri _) async {
      calls++;
      return _release('v9.9.9-beta');
    }

    const int t0 = 1000000000000;
    await checkForNovaUpdate(prefs, nowMs: t0, fetch: fetch);
    // 12 hours later: still within the day, so no second network call.
    await checkForNovaUpdate(prefs, nowMs: t0 + 12 * 3600 * 1000, fetch: fetch);
    expect(calls, 1);
    // 25 hours later: the gate opens again.
    await checkForNovaUpdate(prefs, nowMs: t0 + 25 * 3600 * 1000, fetch: fetch);
    expect(calls, 2);
  });

  test('a remembered newer tag restores the banner on next launch', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.update.latestTag': 'v9.9.9-beta',
      'nova.update.lastCheckMs': 1000000000000,
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // Within the day, so it does not re-fetch, but the stored tag still shows.
    await checkForNovaUpdate(prefs,
        nowMs: 1000000000000 + 3600 * 1000,
        fetch: (_) async => _release('v9.9.9-beta'));
    expect(novaUpdateTag.value, 'v9.9.9-beta');
  });
}
