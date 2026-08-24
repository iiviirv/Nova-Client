import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/features/cloudflare/cloudflare_controller.dart';
import 'package:nova_client/src/features/logs/log_screen.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pumps the Logs screen inside a real app scope. A layout overflow throws in a
/// widget test, so these double as the check that the screen actually fits: an
/// analyzer pass proves the code compiles, not that anything is on screen.
Future<SettingsController> _pumpLogs(
  WidgetTester tester, {
  Size size = const Size(390, 844), // iPhone-class
  double textScale = 1.0,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.dark,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  final ProfilesController profiles = ProfilesController()..attachPrefs(prefs);
  final MockProxyController proxy = MockProxyController();
  final RelayController relay = RelayController();
  final SettingsController settings = SettingsController(prefs: prefs);

  await tester.pumpWidget(NovaScope(
    theme: theme,
    proxy: proxy,
    connInfo: ConnInfoController(proxy),
    profiles: profiles,
    radar: RadarController()..attachPrefs(prefs),
    cloudflare: CloudflareController()..attachPrefs(prefs),
    settings: settings,
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
      themeMode: themeMode,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: const LogScreen(),
      ),
    ),
  ));
  await tester.pump();
  // NovaLog coalesces its notifications on a 250ms timer; let it fire so the
  // test does not end with it pending (and so the first batch is on screen).
  await tester.pump(const Duration(milliseconds: 300));
  return settings;
}

void main() {
  setUp(() {
    NovaLog.instance
      ..clear(NovaLogSource.app)
      ..clear(NovaLogSource.core);
  });

  tearDown(() {
    NovaLog.instance
      ..clear(NovaLogSource.app)
      ..clear(NovaLogSource.core);
  });

  testWidgets('opens on the Nova stream and shows its empty state',
      (WidgetTester tester) async {
    await _pumpLogs(tester);
    expect(find.text('Logs'), findsOneWidget);
    expect(
      find.textContaining('Connect once and the steps Nova takes'),
      findsOneWidget,
    );
  });

  testWidgets('shows app lines, and the core stream separately',
      (WidgetTester tester) async {
    NovaLog.instance.write('Connecting with "Free Nova"');
    NovaLog.instance.writeCore('inbound/tun: started at tun0');
    await _pumpLogs(tester);
    await tester.pump();

    expect(find.textContaining('Connecting with'), findsOneWidget);
    expect(find.textContaining('inbound/tun'), findsNothing,
        reason: 'the core stream is a separate tab');

    await tester.tap(find.text('Core'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('inbound/tun'), findsOneWidget);
    expect(find.textContaining('Connecting with'), findsNothing);
  });

  testWidgets('clearing empties only the stream on screen',
      (WidgetTester tester) async {
    NovaLog.instance.write('app line');
    NovaLog.instance.writeCore('core line');
    await _pumpLogs(tester);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();

    expect(NovaLog.instance.count(NovaLogSource.app), 0);
    expect(NovaLog.instance.count(NovaLogSource.core), 1);
  });

  testWidgets('the verbose-core switch drives the setting',
      (WidgetTester tester) async {
    final SettingsController settings = await _pumpLogs(tester);
    expect(settings.verboseCoreLog, isFalse);

    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump(const Duration(milliseconds: 300));

    expect(settings.verboseCoreLog, isTrue);
    expect(settings.routeOptions.logLevel, 'info');
  });

  testWidgets('a full buffer of long lines lays out without overflowing',
      (WidgetTester tester) async {
    // The real failure mode: 2000 lines, some of them far wider than a phone.
    for (int i = 0; i < NovaLog.maxLines; i++) {
      NovaLog.instance.writeCore(
        'router: connection $i from 10.0.0.$i to a very long destination host '
        'name that is much wider than any phone screen could ever be, twice: '
        'a very long destination host name that is much wider than any phone',
        level: i % 7 == 0
            ? NovaLogLevel.error
            : i % 3 == 0
                ? NovaLogLevel.warn
                : NovaLogLevel.info,
      );
    }
    await _pumpLogs(tester);
    await tester.tap(find.text('Core'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out in Farsi (RTL), in light theme, and at 2x text',
      (WidgetTester tester) async {
    // Three things that break a log screen: mirrored layout, an inverted
    // palette, and accessibility text sizes pushing a fixed row apart.
    NovaLog.instance.write('Connecting with "نوا"');
    NovaLog.instance.writeCore('outbound/vless[proxy]: dialed 1.2.3.4:443');

    await _pumpLogs(tester,
        locale: const Locale('fa'),
        themeMode: ThemeMode.light,
        textScale: 2.0,
        size: const Size(360, 780));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('هسته'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out on a small screen', (WidgetTester tester) async {
    NovaLog.instance.write('a line');
    await _pumpLogs(tester, size: const Size(320, 568)); // iPhone SE 1st gen
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
