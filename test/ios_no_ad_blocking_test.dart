import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App Review rejected Nova under guideline 2.5.1:
///
///   "The app uses a VPN profile or root certificate to block ads or other
///    content in a third-party app, which is not appropriate.
///    Next Steps: To resolve this issue, remove this feature from the app."
///
/// That is Apple's rule for their store and it is not arguable. The feature is
/// removed on iOS and kept everywhere else, because only iOS ships through the
/// App Store. The App Store binary and the TestFlight binary are the same
/// build, so this cannot be narrower than the platform.
///
/// The subtle part, and the one that nearly shipped: the routing options were
/// built from the raw stored field rather than the platform-aware getter, so a
/// value saved by an older version would have switched the feature back on for
/// a reviewer while the switch was hidden from the UI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsController> withStored(bool storedBlockAds) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.route.blockAds': storedBlockAds,
    });
    final SettingsController c =
        SettingsController(prefs: await SharedPreferences.getInstance());
    c.attachPrefs(await SharedPreferences.getInstance());
    return c;
  }

  tearDown(() => SettingsController.debugAdBlockSupportedOverride = null);

  test('on iOS the feature is off however it was stored', () async {
    // Simulated, so this runs on any machine. Previously these tests only ever
    // saw the gate open, and passed whether or not iOS was protected.
    SettingsController.debugAdBlockSupportedOverride = false;
    final SettingsController c = await withStored(true);
    expect(c.blockAds, isFalse,
        reason: 'a value saved before the feature was removed must not turn it '
            'back on for App Review');
    expect(c.routeOptions.blockAds, isFalse,
        reason: 'the config handed to the core is what Apple actually runs, so '
            'this is the assertion that matters');
  });

  test('the platform gate matches the store the app ships through', () {
    expect(SettingsController.adBlockSupported, !Platform.isIOS,
        reason: 'only iOS goes through the App Store; Android, macOS, Windows '
            'and Linux do not and keep the feature');
  });

  test('a stored "on" does not survive onto a platform without the feature',
      () async {
    final SettingsController c = await withStored(true);
    if (Platform.isIOS) {
      expect(c.blockAds, isFalse,
          reason: 'a value saved before the feature was removed must not turn '
              'it back on for App Review');
    } else {
      expect(c.blockAds, isTrue, reason: 'other platforms are unaffected');
    }
  });

  test('the routing options carry the same answer as the getter', () async {
    // The hole that nearly shipped: routeOptions read the raw field, so the
    // config handed to the core could say "block ads" while the UI showed no
    // such switch.
    final SettingsController c = await withStored(true);
    expect(c.routeOptions.blockAds, c.blockAds,
        reason: 'the config sent to the core must agree with the setting the '
            'app reports, or the feature ships invisibly');
  });

  test('turning it off is honoured everywhere', () async {
    final SettingsController c = await withStored(false);
    expect(c.blockAds, isFalse);
    expect(c.routeOptions.blockAds, isFalse);
  });
}
