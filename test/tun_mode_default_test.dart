@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows starts in proxy mode, everything else keeps the whole-device tunnel.
///
/// The tester's report: "you move a finger in the app and it asks for a
/// password". On Windows the tunnel needs an elevation prompt on every connect
/// while the system proxy needs none at all, so proxy mode is the kinder
/// default there. On macOS and Linux the system proxy needs administrator
/// approval too, so the same change would trade one prompt for another.
///
/// The default only applies to a fresh install: a stored choice always wins,
/// which is the half that would have silently changed mode under existing
/// users.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('a stored choice always wins over the default', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.desktop.tun': !(Platform.isMacOS || Platform.isLinux),
    });
    final SettingsController c = SettingsController();
    c.attachPrefs(await SharedPreferences.getInstance());
    expect(c.tunMode, isNot(Platform.isMacOS || Platform.isLinux),
        reason: 'an upgrade must not move anyone to another mode');
  });

  test('a fresh install on this platform gets the platform default', () async {
    final SettingsController c = SettingsController();
    c.attachPrefs(await SharedPreferences.getInstance());
    expect(c.tunMode, Platform.isMacOS || Platform.isLinux);
  });

  test('the choice survives being set', () async {
    final SettingsController c = SettingsController();
    c.attachPrefs(await SharedPreferences.getInstance());
    await c.setTunMode(!c.tunMode);
    final bool now = c.tunMode;
    final SettingsController again = SettingsController();
    again.attachPrefs(await SharedPreferences.getInstance());
    expect(again.tunMode, now);
  });
}
