
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/aether_editor_screen.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:integration_test/integration_test.dart';

/// The editor, driven on a device against the real core.
///
/// The widget tests cover this screen with an injected fake search, and the
/// end-to-end test covers the engine with no screen at all. Neither exercises
/// what a user actually does: open the editor and press the button while a real
/// scan runs. That seam is where a screen whose tests all pass can still sit on
/// a spinner forever, because nothing on the host can load the core to find out.

late ProfilesController profiles;

/// Pumps the editor on a route of its own, so Save's pop has somewhere to go.
Future<void> _open(WidgetTester tester, {AetherGatewaySearch? search}) async {
  // Tall enough that the whole editor is built at once: a ListView does not
  // build what is off screen, and every one of these checks is about what is
  // on the page.
  tester.view.physicalSize = const Size(420, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  profiles = ProfilesController()..attachPrefs(prefs);
  final ProxyController proxy = MockProxyController();
  final RelayController relay = RelayController();

  await tester.pumpWidget(NovaScope(
    theme: theme,
    proxy: proxy,
    connInfo: ConnInfoController(proxy),
    profiles: profiles,
    radar: RadarController()..attachPrefs(prefs),
    settings: SettingsController(prefs: prefs),
    appRouting: AppRouting(),
    vps: VpsController(profiles, proxy, relay),
    relay: relay,
    tunnel: TunnelController(relay.transportFor),
    child: MaterialApp(
      supportedLocales: ThemeController.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        NovaStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: NovaTheme.light(const Locale('en')),
      darkTheme: NovaTheme.dark(const Locale('en')),
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) => TextButton(
            onPressed: () => Navigator.of(ctx).push<void>(
              MaterialPageRoute<void>(
                  builder: (_) => AetherEditorScreen(search: search)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  // The localization delegates resolve asynchronously, so the first frame is
  // an empty box.
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}


void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a real search finds a gateway and shows it',
      (WidgetTester tester) async {
    // No injected search: this is the real core on a real device.
    await _open(tester);
    expect(find.byType(AetherEditorScreen), findsOneWidget);

    final Finder button = find
        .textContaining(RegExp('search|find', caseSensitive: false))
        .first;
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();

    // Pumped, never settled: pumpAndSettle waits for animation to stop and a
    // progress indicator never does.
    final RegExp address = RegExp(r'\d{1,3}(\.\d{1,3}){3}:\d+');
    String seen = '';
    bool found = false;
    for (int i = 0; i < 300; i++) {
      await tester.pump(const Duration(seconds: 1));
      seen = tester
          .widgetList<Text>(find.byType(Text))
          .map((Text w) => w.data ?? '')
          .join(' | ');
      if (address.hasMatch(seen)) {
        // ignore: avoid_print
        print('AETHER_UI_FOUND=${address.firstMatch(seen)!.group(0)}');
        found = true;
        break;
      }
      if (seen.toLowerCase().contains('could not') ||
          seen.toLowerCase().contains('no gateway')) {
        break;
      }
    }
    // ignore: avoid_print
    print('AETHER_UI_RESULT found=$found screen="$seen"');
    expect(found, isTrue,
        reason: 'the search never put an address on screen');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
