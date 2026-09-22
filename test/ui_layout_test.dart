import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/dashboard/dashboard_screen.dart';
import 'package:nova_client/src/features/onboarding/onboarding_screen.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/aether_editor_screen.dart';
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
  _StaticProxy(this._state, {this.profile, this.localPort});

  final ProxyConnectionState _state;
  final ProxyProfile? profile;
  final int? localPort;

  @override
  int? get localProxyPort => localPort;

  // A local port alone no longer means proxy mode: per-app routing opens one
  // too, purely so the app can reach its own tunnel.
  @override
  bool get isProxyMode => localPort != null;

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
  bool freeTab = false,
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
    ..attachPrefs(prefs)
    ..selectTab(freeTab);
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
    settings: SettingsController(prefs: prefs),
    appRouting: AppRouting(),
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

    testWidgets('desktop proxy mode shows the local proxy address card',
        (WidgetTester tester) async {
      final ProxyProfile sub = _subscription();
      await _pump(
        tester,
        const DashboardScreen(),
        proxy: _StaticProxy(ProxyConnectionState.connected,
            profile: sub, localPort: 2080),
        profiles: <ProxyProfile>[sub],
      );
      expect(tester.takeException(), isNull);
      expect(find.text('127.0.0.1:2080'), findsOneWidget);
      // The system proxy is a switch bound to the setting, not a one-shot
      // button: a Windows tester had to press the old button after every
      // connect, because the proxy is cleared on every disconnect.
      expect(find.text('Set system proxy automatically'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
      await _teardown(tester);
    });

    testWidgets('no local proxy port (mobile / TUN): no proxy card',
        (WidgetTester tester) async {
      final ProxyProfile sub = _subscription();
      await _pump(
        tester,
        const DashboardScreen(),
        proxy: _StaticProxy(ProxyConnectionState.connected, profile: sub),
        profiles: <ProxyProfile>[sub],
      );
      expect(find.text('Set system proxy'), findsNothing);
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
    testWidgets('Free options localize and fit Farsi at 320dp and 2x text', (tester) async {
      await _pump(tester, const ServersScreen(), freeTab: true,
          textScale: 2.0, locale: const Locale('fa'), themeMode: ThemeMode.light);
      expect(find.text('رایگان'), findsOneWidget);
      expect(find.text('اشتراک‌ها'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('سرورهای رایگان نوا'), 150,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('سرورهای رایگان نوا'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });
    testWidgets('rows lay out at 320dp and 2x text',
        (WidgetTester tester) async {
      await _pump(tester, const ServersScreen(),
          profiles: <ProxyProfile>[_subscription(), _single()], textScale: 2.0);
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
    testWidgets('connection guide can be opened and closed from Settings',
        (WidgetTester tester) async {
      await _pump(tester, const SettingsScreen());
      await tester.tap(find.text('Connection guide'));
      await tester.pumpAndSettle();
      expect(find.text('Three ways to get connected'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Connection guide'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _teardown(tester);
    });

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

  group('Aether editor', () {
    // The editor is the densest screen in the app: five choice groups, a field
    // and a live status line. At 320dp with doubled text the pill rows are what
    // break first, and a Wrap that cannot wrap throws rather than looking bad.

    /// Drags the whole screen past the viewport.
    ///
    /// An overflow only throws when the offending row is PAINTED, and a
    /// ListView paints nothing below the fold. Pumping this screen and looking
    /// at the exception without scrolling passed against a version whose pills
    /// could not wrap at all, so the scroll is the test.
    Future<void> scrollThrough(WidgetTester tester) async {
      final Finder list = find.byType(Scrollable).first;
      for (int i = 0; i < 12; i++) {
        expect(tester.takeException(), isNull);
        await tester.drag(list, const Offset(0, -300));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    }

    for (final locale in [const Locale('en'), const Locale('fa')]) {
      testWidgets(
          'fragment fields fit at 320dp and 2x text in ${locale.languageCode}',
          (tester) async {
        final profile = ProxyProfile(
            id: 'fragment',
            name: 'HTTP2',
            kind: ProxyKind.aether,
            uri:
                'aether://1.2.3.4:443?protocol=masque&transport=h2&fragment=1&fragment_size=18-30&fragment_delay=3-8',
            updatedAt: DateTime(2026));
        await _pump(tester, AetherEditorScreen(existing: profile),
            locale: locale, textScale: 2, themeMode: ThemeMode.light);
        final field =
            find.byKey(const ValueKey<String>('aether-fragment-delay'));
        await tester.scrollUntilVisible(field, 200,
            scrollable: find.byType(Scrollable).first);
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, '3-8');
        expect(tester.takeException(), isNull);
        await scrollThrough(tester);
        await _teardown(tester);
      });
    }

    testWidgets('lays out at 320dp and 2x text', (WidgetTester tester) async {
      await _pump(tester, const AetherEditorScreen(), textScale: 2.0);
      await scrollThrough(tester);
      await _teardown(tester);
    });

    testWidgets('lays out in Farsi, light, at 2x text',
        (WidgetTester tester) async {
      await _pump(tester, const AetherEditorScreen(),
          textScale: 2.0,
          locale: const Locale('fa'),
          themeMode: ThemeMode.light);
      await scrollThrough(tester);
      await _teardown(tester);
    });

    testWidgets('the gool hop fields lay out too', (WidgetTester tester) async {
      await _pump(tester, const AetherEditorScreen(), textScale: 2.0);
      await tester.scrollUntilVisible(find.text('gool'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(find.text('gool'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('gool'));
      await tester.pumpAndSettle();
      await scrollThrough(tester);
      await _teardown(tester);
    });
  });

  group('Onboarding', () {
    Widget onboarding() =>
        NovaOnboarding(onPickLanguage: (_) {}, onFinish: (_) {});

    testWidgets('all steps lay out at 320dp and 2x text',
        (WidgetTester tester) async {
      await _pump(tester, onboarding(), textScale: 2.0);
      expect(tester.takeException(), isNull);
      expect(find.text('Welcome to Nova'), findsOneWidget);

      await tester.ensureVisible(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Three ways to get connected'), findsOneWidget);
      await tester.ensureVisible(find.text('Choose how to start'));
      await tester.tap(find.text('Choose how to start'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('How would you like to start?'), findsOneWidget);
      expect(find.text('Use the free servers'), findsOneWidget);
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
