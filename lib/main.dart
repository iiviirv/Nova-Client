import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/core/proxy/mock_proxy_controller.dart';
import 'src/core/proxy/proxy_controller.dart';
import 'src/features/profiles/profiles_controller.dart';
import 'src/features/radar/radar_controller.dart';
import 'src/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Construct controllers up front so the first frame is correct, then attach
  // persisted state once SharedPreferences resolves.
  final ThemeController theme = ThemeController();
  final ProfilesController profiles = ProfilesController();
  final RadarController radar = RadarController();

  // The data path is a modified sing-box core, bound natively per platform.
  // That native binding is out of scope for this milestone, so the UI runs
  // against the simulated controller. Swap this single line for
  // `SingboxProxyController()` once the platform hosts ship — no UI changes.
  final ProxyController proxy = MockProxyController();

  runApp(NovaApp(
    theme: theme,
    proxy: proxy,
    profiles: profiles,
    radar: radar,
  ));

  // Hydrate persisted preferences without blocking first paint.
  SharedPreferences.getInstance().then((prefs) {
    theme.attachPrefs(prefs);
    profiles.attachPrefs(prefs);
    radar.attachPrefs(prefs);

    // If a subscription is active, bind it to the Radar in the background so
    // scans export ready-to-import nodes without the user lifting a finger.
    final active = profiles.active;
    if (active != null &&
        active.isSubscription &&
        (active.subscriptionUrl ?? '').isNotEmpty) {
      radar.bindSubscription(active.subscriptionUrl!);
    }
  });
}
