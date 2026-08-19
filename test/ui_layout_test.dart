import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/cloudflare/cloudflare_controller.dart';
import 'package:nova_client/src/features/cloudflare/deploy_screen.dart';
import 'package:nova_client/src/features/dashboard/dashboard_screen.dart';
import 'package:nova_client/src/features/onboarding/onboarding_screen.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/servers_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/core/update/update_checker.dart';
import 'package:nova_client/src/features/settings/settings_screen.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Layout checks for the restyled screens (Dashboard, Servers, Settings,
/// Onboarding). A layout overflow throws in a widget test, so pumping each
/// screen at a 320dp width and at a 2x text scale, in both scripts and both
/// themes, is the check that the screen actually fits; the analyzer only proves
/// it compiles.

/// A proxy that reports whatever [state] it was given and never notifies, so
/// the connected dashboard can be laid out without the conn-info controller
/// starting its probe timers.
class _StaticProxy extends ProxyController {
  _StaticProxy(this._state, {this.profile});

  final ProxyConnectionState _state;
  final ProxyProfile? profile;

  @override
  ProxyConnectionState get state => _state;

  @override
  TrafficStats get traffic =>
      const TrafficStats(uplinkBps: 123456, downlinkBps: 9876543);

  @override
  ProxyProfile? get activeProfile => profile;

  @override
  String? get lastError => null;

  @override
  void selectProfile(ProxyProfile? profile) {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}
}

ProxyProfile _subscription() => ProxyProfile(
      id: 'sub-1',
      name: 'A very long subscription name that should truncate on a phone',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.invalid/sub',
      nodeCount: 17,
      lastLatencyMs: 42,
      updatedAt: DateTime(2026, 1, 1),
    );

ProxyProfile _single() => ProxyProfile(
      id: 'vless-1',
      name: 'DeadNode',
      kind: ProxyKind.vless,
      uri: 'vless://00000000-0000-0000-0000-000000000000@1.2.3.4:443',
      updatedAt: DateTime(2026, 1, 1),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(320, 640),
  double textScale = 1.0,
  Locale locale = const Locale('en'),
  ThemeMode themeMode = ThemeMode.dark,
  ProxyController? proxy,
  List<ProxyProfile> profiles = const <ProxyProfile>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  final ProfilesController profileCtl = ProfilesController()
    ..attachPrefs(prefs);
  for (final ProxyProfile p in profiles) {
    profileCtl.add(p);
  }
  final ProxyController proxyCtl = proxy ?? MockProxyController();
  final RelayController relay = RelayController();

  await tester.pumpWidget(NovaScope(
    theme: theme,
    proxy: proxyCtl,
    connInfo: ConnInfoController(proxyCtl),
    profiles: profileCtl,
    radar: RadarController()..attachPrefs(prefs),
    cloudflare: CloudflareController()..attachPrefs(prefs),
    settings: SettingsController(prefs: prefs),
    vps: VpsController(profileCtl, proxyCtl, relay),
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
        child: Scaffold(body: screen),
      ),
    ),
  ));
  await tester.pump();
}

/// Tears the tree down so widget-owned tickers (the uptime clock) are gone
/// before the test ends.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('Dashboard', () {
    testWidgets('idle, with a profile, at 320dp', (WidgetTester tester) async {
      await _pump(tester, const DashboardScreen(),
          profiles: <ProxyProfile>[_subscription(), _single()]);
      expect(tester.takeException(), isNull);
      expect(find.text('Tap to connect'), findsOneWidget);
      // The idle hero carries the "not protected" hint; no separate card.
      expect(find.text('Connect to route your traffic through Nova.'),
          findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('idle without a profile shows no config card, tools hidden',
        (WidgetTester tester) async {
      await _pump(tester, const DashboardScreen());
      expect(tester.takeException(), isNull);
      // The Radar/Deploy/Panel strip is intentionally hidden for now
      // (kShowDashboardTools), and with no profile there is no config card.
      expect(find.text('Radar'), findsNothing);
      expect(find.text('Single config'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('connected: connection panel lays out at 320dp and 2x text',
        (WidgetTester tester) async {
      final ProxyProfile sub = _subscription();
      await _pump(
        tester,
        const DashboardScreen(),
        proxy: _StaticProxy(ProxyConnectionState.connected, profile: sub),
        profiles: <ProxyProfile>[sub],
        textScale: 2.0,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Connected'), findsOneWidget);
      // Location / IP / Ping and both throughput readings are on screen.
      expect(find.text('LOCATION'), findsOneWidget);
      expect(find.text('PING'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      // The uptime clock ticks; a second passing must not throw.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });

    testWidgets('connected, Farsi, light, at 2x text',
        (WidgetTester tester) async {
      final ProxyProfile sub = _subscription();
      await _pump(
        tester,
        const DashboardScreen(),
        proxy: _StaticProxy(ProxyConnectionState.connected, profile: sub),
        profiles: <ProxyProfile>[sub],
        locale: const Locale('fa'),
        themeMode: ThemeMode.light,
        textScale: 2.0,
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull);
      // Farsi labels stay plain (no uppercasing/tracking) and the ping label
      // is localised rather than a Latin "PING".
      expect(find.text('پینگ'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('error state shows the error under the headline',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const DashboardScreen(),
        proxy: _StaticProxy(ProxyConnectionState.error),
        textScale: 2.0,
      );
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });
  });

  group('Servers', () {
    testWidgets('rows lay out at 320dp and 2x text',
        (WidgetTester tester) async {
      await _pump(tester, const ServersScreen(),
          profiles: <ProxyProfile>[_subscription(), _single()],
          textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('17 nodes'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('Farsi light at 320dp', (WidgetTester tester) async {
      await _pump(tester, const ServersScreen(),
          profiles: <ProxyProfile>[_subscription(), _single()],
          locale: const Locale('fa'),
          themeMode: ThemeMode.light);
      expect(tester.takeException(), isNull);
      expect(find.text('همه'), findsOneWidget);
      expect(find.text('17 سرور'), findsNothing,
          reason: 'the row uses the shared nodesCount string');
      expect(find.text('17 نود'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('empty state at 320dp and 2x text',
        (WidgetTester tester) async {
      await _pump(tester, const ServersScreen(), textScale: 2.0);
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });
  });

  group('Settings', () {
    testWidgets('lays out at 320dp and 2x text, English dark',
        (WidgetTester tester) async {
      await _pump(tester, const SettingsScreen(), textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('GENERAL'), findsOneWidget,
          reason: 'section labels are Latin eyebrows');
      // The footer is far below the fold at this scale; scroll it in.
      await tester.scrollUntilVisible(
        find.text('v$kNovaVersion ($kNovaBuild)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('v$kNovaVersion ($kNovaBuild)'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('lays out at 320dp and 2x text, Farsi light',
        (WidgetTester tester) async {
      await _pump(tester, const SettingsScreen(),
          textScale: 2.0,
          locale: const Locale('fa'),
          themeMode: ThemeMode.light);
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });

    testWidgets('theme pills drive the theme controller',
        (WidgetTester tester) async {
      await _pump(tester, const SettingsScreen());
      final ThemeController theme =
          NovaScope.of(tester.element(find.byType(SettingsScreen))).theme;
      await tester.scrollUntilVisible(find.text('Light'), 200,
          scrollable: find.byType(Scrollable).first);
      // scrollUntilVisible stops as soon as the pill is *built*, which on the
      // 640px test surface can still be inside the list's cache extent just
      // below the fold (the panel section above it made Settings taller).
      // ensureVisible brings it fully on screen so the tap lands.
      await tester.ensureVisible(find.text('Light'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(theme.themeMode, ThemeMode.light);
      await _teardown(tester);
    });
  });

  group('Deploy', () {
    testWidgets('bot hand-off lays out at 320dp and 2x text, English dark',
        (WidgetTester tester) async {
      await _pump(tester, const DeployScreen(), textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('Deploy with the Nova bot'), findsOneWidget);
      // The steps and the hand-off button are below the fold at 2x on a 320dp
      // phone; scroll them in and confirm they lay out.
      await tester.scrollUntilVisible(
        find.text('Open the Nova bot'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Open the bot and tap Start.'), findsOneWidget);
      expect(find.text('Open the Nova bot'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('bot hand-off lays out at 320dp and 2x text, Farsi light',
        (WidgetTester tester) async {
      await _pump(tester, const DeployScreen(),
          textScale: 2.0,
          locale: const Locale('fa'),
          themeMode: ThemeMode.light);
      expect(tester.takeException(), isNull);
      expect(find.text('استقرار با ربات نوا'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('Onboarding', () {
    Widget onboarding() =>
        NovaOnboarding(onPickLanguage: (_) {}, onFinish: (_) {});

    testWidgets('both steps lay out at 320dp and 2x text',
        (WidgetTester tester) async {
      await _pump(tester, onboarding(), textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('Welcome to Nova'), findsOneWidget);

      await tester.ensureVisible(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('How would you like to start?'), findsOneWidget);
      expect(find.text('Connect your VPS'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('switching to Farsi flips the copy and direction',
        (WidgetTester tester) async {
      await _pump(tester, onboarding(), themeMode: ThemeMode.light);
      await tester.tap(find.text('فارسی'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('به نوا خوش آمدید'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('به نوا خوش آمدید'))),
        TextDirection.rtl,
      );
      await _teardown(tester);
    });
  });
}
