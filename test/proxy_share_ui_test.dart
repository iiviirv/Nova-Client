import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/dashboard/dashboard_screen.dart';
import 'package:nova_client/src/features/dashboard/lan_share_probe.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/routing/routing_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The UI for sharing the local proxy on the network. The logic is covered in
/// proxy_share_lan_test.dart; these are about what a person is told, and
/// whether it is true.
///
/// The routing tests run the desktop layout (TUN off), which is what a
/// desktop test host gets. The phone layout puts the same section under the
/// proxy-mode switch.

class _StaticProxy extends ProxyController {
  _StaticProxy(this._state, {this.profile, this.localPort, this.sharedPort, this.proxyMode = true});

  final ProxyConnectionState _state;
  final ProxyProfile? profile;
  final int? localPort;
  final int? sharedPort;
  final bool proxyMode;

  @override
  int? get sharedProxyPort => sharedPort;

  @override
  int? get localProxyPort => localPort;

  @override
  bool get isProxyMode => proxyMode && localPort != null;

  @override
  ProxyConnectionState get state => _state;

  @override
  TrafficStats get traffic => const TrafficStats();

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

ProxyProfile _sub() => ProxyProfile(
      id: 'sub-1',
      name: 'Home',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.invalid/sub',
      nodeCount: 3,
      updatedAt: DateTime(2026, 1, 1),
    );

Future<SettingsController> _pump(
  WidgetTester tester,
  Widget home, {
  Map<String, Object> prefs = const <String, Object>{},
  Size size = const Size(800, 3000),
  double textScale = 1.0,
  Locale locale = const Locale('en'),
  ProxyController? proxy,
  List<ProxyProfile> profiles = const <ProxyProfile>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // TUN off so the desktop layout shows the proxy port and the share switch.
  SharedPreferences.setMockInitialValues(<String, Object>{
    'nova.desktop.tun': false,
    ...prefs,
  });
  final SharedPreferences sp = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(sp);
  final ProfilesController profileCtl = ProfilesController()..attachPrefs(sp);
  for (final ProxyProfile p in profiles) {
    profileCtl.add(p);
  }
  final ProxyController proxyCtl = proxy ?? MockProxyController();
  final RelayController relay = RelayController();
  final SettingsController settings = SettingsController(prefs: sp);

  await tester.pumpWidget(NovaScope(
    theme: theme,
    proxy: proxyCtl,
    connInfo: ConnInfoController(proxyCtl),
    profiles: profileCtl,
    radar: RadarController()..attachPrefs(sp),
    settings: settings,
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
      themeMode: ThemeMode.dark,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: home,
      ),
    ),
  ));
  await tester.pump();
  return settings;
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

final NovaStrings _en = NovaStrings(const Locale('en'));

Finder get _userField => find.byKey(const ValueKey<String>('proxyShareUser'));
Finder get _passField => find.byKey(const ValueKey<String>('proxySharePass'));

void main() {
  group('Settings: share switch', () {
    testWidgets('sharing remains available with the full-device tunnel on',
        (WidgetTester tester) async {
      await _pump(tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.desktop.tun': true});
      expect(find.text(_en.routeShare), findsOneWidget);
      await tester.tap(find.text(_en.routeShare));
      await tester.pumpAndSettle();
      expect(find.text(_en.routeShareConfirmTitle), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('off by default, and no login fields while off',
        (WidgetTester tester) async {
      final SettingsController settings =
          await _pump(tester, const RoutingScreen());
      expect(find.text(_en.routeShare), findsOneWidget);
      expect(settings.proxyShareOnLan, isFalse);
      // A password on a port nobody else can reach protects nothing, so the
      // fields must not suggest otherwise.
      expect(_userField, findsNothing);
      expect(_passField, findsNothing);
      await _teardown(tester);
    });

    testWidgets('turning it on asks first, and Cancel leaves it off',
        (WidgetTester tester) async {
      final SettingsController settings =
          await _pump(tester, const RoutingScreen());
      await tester.tap(find.text(_en.routeShare));
      await tester.pumpAndSettle();

      expect(find.text(_en.routeShareConfirmTitle), findsOneWidget);
      // The warning names the actual port and says who can get in.
      expect(find.text(_en.routeShareConfirmBody(2080)), findsOneWidget);
      expect(_en.routeShareConfirmBody(2080), contains('2080'));
      expect(_en.routeShareConfirmBody(2080), contains('internet'));

      await tester.tap(find.text(_en.cancel));
      await tester.pumpAndSettle();
      expect(settings.proxyShareOnLan, isFalse);
      expect(_userField, findsNothing);
      await _teardown(tester);
    });

    testWidgets('confirming turns it on and shows the open warning',
        (WidgetTester tester) async {
      final SettingsController settings = await _pump(
          tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.proxy.port': 3128});
      await tester.tap(find.text(_en.routeShare));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_en.routeShareConfirm));
      await tester.pumpAndSettle();

      expect(settings.proxyShareOnLan, isTrue);
      expect(_userField, findsOneWidget);
      expect(_passField, findsOneWidget);
      // The warning follows the port the user actually set.
      expect(find.text(_en.routeShareOpen(3128)), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('the status only calms down once both login fields are set',
        (WidgetTester tester) async {
      final SettingsController settings = await _pump(
          tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.proxy.shareOnLan': true});
      expect(find.text(_en.routeShareOpen(2080)), findsOneWidget);

      await tester.enterText(_userField, 'tv');
      await tester.pump();
      // One field is not a login: the core leaves the port open.
      expect(find.text(_en.routeShareHalf), findsOneWidget);
      expect(find.text(_en.routeShareLocked), findsNothing);

      await tester.enterText(_passField, 's3cret');
      await tester.pump();
      expect(find.text(_en.routeShareLocked), findsOneWidget);
      expect(settings.proxyShareUser, 'tv');
      expect(settings.proxySharePass, 's3cret');

      // And clearing one opens it again.
      await tester.enterText(_passField, '');
      await tester.pump();
      expect(find.text(_en.routeShareHalf), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('the password is hidden until asked',
        (WidgetTester tester) async {
      await _pump(tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.proxy.shareOnLan': true});
      TextField field() => tester.widget<TextField>(_passField);
      expect(field().obscureText, isTrue);
      await tester.tap(find.byTooltip(_en.routeSharePassShow));
      await tester.pump();
      expect(field().obscureText, isFalse);
      await _teardown(tester);
    });

    testWidgets('turning it off does not ask, and the fields go',
        (WidgetTester tester) async {
      final SettingsController settings = await _pump(
          tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.proxy.shareOnLan': true});
      await tester.tap(find.text(_en.routeShare));
      await tester.pumpAndSettle();
      expect(find.text(_en.routeShareConfirmTitle), findsNothing);
      expect(settings.proxyShareOnLan, isFalse);
      expect(_userField, findsNothing);
      await _teardown(tester);
    });

    testWidgets('Farsi at 320dp and 2x text lays out with sharing on',
        (WidgetTester tester) async {
      await _pump(tester, const RoutingScreen(),
          prefs: <String, Object>{'nova.proxy.shareOnLan': true},
          size: const Size(320, 6000),
          textScale: 2.0,
          locale: const Locale('fa'));
      expect(tester.takeException(), isNull);
      final NovaStrings fa = NovaStrings(const Locale('fa'));
      expect(find.text(fa.routeShareOpen(2080)), findsOneWidget);
      // The port sits inside a left-to-right isolate so it does not flip.
      expect(fa.routeShareOpen(2080), contains('\u20662080\u2069'));
      await _teardown(tester);
    });

    testWidgets('the Farsi confirm fits a 320dp phone at 2x text',
        (WidgetTester tester) async {
      await _pump(tester, const RoutingScreen(),
          size: const Size(320, 640),
          textScale: 2.0,
          locale: const Locale('fa'));
      final NovaStrings fa = NovaStrings(const Locale('fa'));
      // The list builds lazily, so scroll the row into existence first.
      await tester.scrollUntilVisible(find.text(fa.routeShare), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(fa.routeShare));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(fa.routeShareConfirmTitle), findsOneWidget);
      expect(find.text(fa.routeShareConfirm), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('Dashboard: shared address', () {
    late Future<List<String>> Function() savedList;
    late Future<bool?> Function(String, int) savedKnock;

    setUp(() {
      savedList = LanShareProbe.listAddresses;
      savedKnock = LanShareProbe.knock;
    });
    tearDown(() {
      LanShareProbe.listAddresses = savedList;
      LanShareProbe.knock = savedKnock;
    });

    void fakeNetwork(List<String> addrs, bool? Function(String host) answer) {
      LanShareProbe.listAddresses = () async => addrs;
      LanShareProbe.knock = (String host, int port) async => answer(host);
    }

    Future<void> pumpConnected(WidgetTester tester,
        {bool shareOn = true, bool tunMode = false}) async {
      final ProxyProfile sub = _sub();
      await _pump(
        tester,
        const Scaffold(body: DashboardScreen()),
        prefs: <String, Object>{'nova.proxy.shareOnLan': shareOn},
        size: const Size(400, 2000),
        proxy: _StaticProxy(ProxyConnectionState.connected,
            profile: sub, localPort: 2080, sharedPort: tunMode ? 2080 : null, proxyMode: !tunMode),
        profiles: <ProxyProfile>[sub],
      );
      await tester.pump();
    }

    testWidgets('TUN sharing shows its live address after settings are disabled',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => true);
      await pumpConnected(tester, tunMode: true, shareOn: false);
      expect(find.text('192.168.1.42:2080'), findsOneWidget);
      expect(find.text(_en.routeShare), findsOneWidget);
      expect(find.text(_en.routeSysProxy), findsNothing);
      await _teardown(tester);
    });

    testWidgets('shared and open: the LAN address and an open warning',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => false);
      await pumpConnected(tester);
      expect(find.text('127.0.0.1:2080'), findsOneWidget);
      expect(find.text(_en.proxyModeLan), findsOneWidget);
      expect(find.text('192.168.1.42:2080'), findsOneWidget);
      expect(find.text(_en.proxyModeLanOpen), findsOneWidget);
      expect(find.text(_en.proxyModeLanLocked), findsNothing);
      await _teardown(tester);
    });

    testWidgets('shared with a login: says so',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => true);
      await pumpConnected(tester);
      expect(find.text('192.168.1.42:2080'), findsOneWidget);
      expect(find.text(_en.proxyModeLanLocked), findsOneWidget);
      expect(find.text(_en.proxyModeLanOpen), findsNothing);
      await _teardown(tester);
    });

    testWidgets('only addresses that answered are shown',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42', '10.0.0.7'],
          (String h) => h == '10.0.0.7' ? false : null);
      await pumpConnected(tester);
      expect(find.text('10.0.0.7:2080'), findsOneWidget);
      expect(find.text('192.168.1.42:2080'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('never shared: nothing about other devices',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => null);
      await pumpConnected(tester, shareOn: false);
      expect(find.text('127.0.0.1:2080'), findsOneWidget);
      expect(find.text(_en.proxyModeLan), findsNothing);
      expect(find.textContaining('192.168.1.42'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('switched on but not live yet: no address, says reconnect',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => null);
      await pumpConnected(tester);
      expect(find.textContaining('192.168.1.42'), findsNothing);
      expect(find.text(_en.proxyModeLanPending), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('no local network: says so instead of guessing',
        (WidgetTester tester) async {
      fakeNetwork(const <String>[], (_) => false);
      await pumpConnected(tester);
      expect(find.text(_en.proxyModeLanNoNetwork), findsOneWidget);
      expect(find.text(_en.proxyModeLanPending), findsNothing);
      await _teardown(tester);
    });

    // The dangerous half of "Settings and the running proxy disagree".
    testWidgets('switched off while still open: keeps showing the address',
        (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => false);
      await pumpConnected(tester, shareOn: false);
      expect(find.text('192.168.1.42:2080'), findsOneWidget);
      expect(find.text(_en.proxyModeLanStill), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('tapping the address copies it', (WidgetTester tester) async {
      fakeNetwork(<String>['192.168.1.42'], (_) => false);
      final List<String> copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpConnected(tester);
      await tester.tap(find.text('192.168.1.42:2080'));
      await tester.pump();
      expect(copied, <String>['192.168.1.42:2080']);
      await _teardown(tester);
    });
  });

  group('LanShareProbe', () {
    test('private ranges only', () {
      for (final String ip in <String>[
        '10.0.0.1', '172.16.0.1', '172.31.255.254', '192.168.1.42',
      ]) {
        expect(LanShareProbe.isPrivateIpv4(ip), isTrue, reason: ip);
      }
      for (final String ip in <String>[
        '127.0.0.1', '8.8.8.8', '172.15.0.1', '172.32.0.1', '169.254.1.1',
        '100.64.0.1', '192.169.0.1', 'not.an.ip.x', '1.2.3',
      ]) {
        expect(LanShareProbe.isPrivateIpv4(ip), isFalse, reason: ip);
      }
    });

    // Real sockets on loopback, standing in for the core's mixed inbound.
    Future<ServerSocket> fakeSocks(List<int> reply) async {
      final ServerSocket server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((Socket c) {
        c.listen((_) {
          c.add(reply);
          unawaited(c.flush().then((_) => c.close()));
        }, onError: (_) {});
      });
      return server;
    }

    test('a SOCKS5 server with no users reads as open', () async {
      final ServerSocket s = await fakeSocks(<int>[0x05, 0x00]);
      addTearDown(s.close);
      expect(await LanShareProbe.socksKnock('127.0.0.1', s.port), isFalse);
    });

    test('a SOCKS5 server that wants a login reads as locked', () async {
      final ServerSocket s = await fakeSocks(<int>[0x05, 0xFF]);
      addTearDown(s.close);
      expect(await LanShareProbe.socksKnock('127.0.0.1', s.port), isTrue);
    });

    // Measured against the shipped sing-box too: with users set, its reply to
    // a no-login greeting starts 0x05 0xFF. TCP may hand those over one byte
    // at a time, and reading only the first chunk would call it open.
    test('a login reply split across reads still reads as locked', () async {
      final ServerSocket server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((Socket c) {
        c.listen((_) async {
          c.add(<int>[0x05]);
          await c.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          c.add(<int>[0xFF]);
          await c.flush();
          await c.close();
        }, onError: (_) {});
      });
      expect(await LanShareProbe.socksKnock('127.0.0.1', server.port), isTrue);
    });

    test('something that is not SOCKS5 reads as open, never as locked',
        () async {
      final ServerSocket s = await fakeSocks('HTTP/1.1 400'.codeUnits);
      addTearDown(s.close);
      expect(await LanShareProbe.socksKnock('127.0.0.1', s.port), isFalse);
    });

    test('nothing listening reads as unreachable', () async {
      final ServerSocket s =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = s.port;
      await s.close();
      expect(await LanShareProbe.socksKnock('127.0.0.1', port), isNull);
    });
  });
}
