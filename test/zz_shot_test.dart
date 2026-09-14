import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:nova_client/src/features/servers/servers_body.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _loadFonts() async {
  for (final String fam in <String>['Inter', 'Vazirmatn']) {
    final FontLoader l = FontLoader(fam);
    for (final String f in <String>['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      l.addFont(File('assets/fonts/Vazirmatn-$f.ttf').readAsBytes().then(
          (List<int> b) => ByteData.view(Uint8List.fromList(b).buffer)));
    }
    await l.load();
  }
}

Future<void> _pump(WidgetTester tester, Widget home, Locale locale, ThemeMode mode) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  final ProfilesController profiles = ProfilesController()..attachPrefs(prefs);
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
      locale: locale,
      supportedLocales: ThemeController.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        NovaStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: NovaTheme.light(locale),
      darkTheme: NovaTheme.dark(locale),
      themeMode: mode,
      home: home,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('shot: editor en dark', (WidgetTester tester) async {
    await tester.runAsync(_loadFonts);
    tester.view.physicalSize = const Size(420, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester, const AetherEditorScreen(), const Locale('en'), ThemeMode.dark);
    await expectLater(find.byType(AetherEditorScreen),
        matchesGoldenFile('shots/editor_en_dark.png'));
  });

}
