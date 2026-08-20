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

  test('the gate skips a second check inside the window, opens after it', () async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    int calls = 0;
    Future<String> fetch(Uri _) async {
      calls++;
      return _release('v9.9.9-beta');
    }

    const int t0 = 1000000000000;
    await checkForNovaUpdate(prefs, nowMs: t0, fetch: fetch);
    // Inside the window: no second network call.
    await checkForNovaUpdate(prefs,
        nowMs: t0 + kUpdateCheckGateMs ~/ 2, fetch: fetch);
    expect(calls, 1);
    // Past it: the gate opens again. Three hours, not a day: during a beta a
    // daily gate meant a user two releases behind heard nothing.
    await checkForNovaUpdate(prefs,
        nowMs: t0 + kUpdateCheckGateMs + 1000, fetch: fetch);
    expect(calls, 2);
    expect(kUpdateCheckGateMs, 3 * 60 * 60 * 1000);
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

  test('a manual check reports what it found', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      await checkForNovaUpdateNow(prefs,
          fetch: (Uri _) async => _release('v99.0.0-beta')),
      NovaUpdateCheck.updateAvailable,
    );
    expect(
      await checkForNovaUpdateNow(prefs,
          fetch: (Uri _) async => _release(kNovaReleaseTag)),
      NovaUpdateCheck.upToDate,
    );
    // An older tag than this build is not an update either.
    expect(
      await checkForNovaUpdateNow(prefs,
          fetch: (Uri _) async => _release('v1.0.0-beta')),
      NovaUpdateCheck.upToDate,
    );
  });
}
