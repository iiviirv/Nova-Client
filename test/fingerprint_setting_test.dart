import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';

void main() {
  test('manual fingerprint flows into routeOptions and persists', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SettingsController s = SettingsController(prefs: prefs);

    // Default is Auto: no override (the ISP resolver / node value applies).
    expect(s.fingerprint, '');
    expect(s.routeOptions.fingerprintOverride, isNull);

    await s.setFingerprint('firefox');
    expect(s.fingerprint, 'firefox');
    expect(s.routeOptions.fingerprintOverride, 'firefox');

    // Persisted across a reload.
    final SettingsController s2 = SettingsController(prefs: prefs);
    expect(s2.fingerprint, 'firefox');
    expect(s2.routeOptions.fingerprintOverride, 'firefox');

    // Back to Auto clears the override.
    await s2.setFingerprint('');
    expect(s2.routeOptions.fingerprintOverride, isNull);
  });

  test('kFingerprintChoices leads with Auto and includes the DPI options', () {
    expect(kFingerprintChoices.first, '');
    expect(kFingerprintChoices, containsAll(<String>['chrome', 'firefox', 'randomized']));
  });
}
