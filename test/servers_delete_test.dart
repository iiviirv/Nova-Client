import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/cloudflare/cloudflare_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/servers_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Field report: "deleting an AmneziaWG config sometimes deleted one of my
/// subscriptions". The subscription was never deleted. The Servers list keeps
/// a kind filter; once the last profile of that kind is removed the chip that
/// could clear the filter is gone, so every remaining profile was hidden
/// behind a filter nobody could see. These tests pin the fix, the keyed rows,
/// the delete confirmation, and the controller's pre-prefs replay.

ProxyProfile _sub(String id, String name) => ProxyProfile(
      id: id,
      name: name,
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.invalid/$id',
      updatedAt: DateTime(2026, 1, 1),
    );

ProxyProfile _awg(String id, String name) => ProxyProfile(
      id: id,
      name: name,
      kind: ProxyKind.awg,
      uri: '[Interface]\nPrivateKey = x\nAddress = 10.0.0.2/32\n'
          '[Peer]\nPublicKey = y\nEndpoint = 1.2.3.4:51820\n',
      updatedAt: DateTime(2026, 1, 1),
    );

Future<ProfilesController> _pumpServers(
  WidgetTester tester,
  List<ProxyProfile> profiles,
) async {
  tester.view.physicalSize = const Size(400, 900);
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
  final ProxyController proxyCtl = MockProxyController();
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
      locale: const Locale('en'),
      supportedLocales: ThemeController.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        NovaStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: NovaTheme.dark(const Locale('en')),
      darkTheme: NovaTheme.dark(const Locale('en')),
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: ServersScreen()),
    ),
  ));
  await tester.pump();
  return profileCtl;
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('Servers list delete', () {
    testWidgets(
        'deleting the only AmneziaWG config while filtered to AmneziaWG '
        'keeps the subscriptions visible', (WidgetTester tester) async {
      final ProfilesController profiles = await _pumpServers(tester, <ProxyProfile>[
        _sub('s1', 'Germany sub'),
        _sub('s2', 'Holland sub'),
        _awg('w1', 'Office WG'),
      ]);

      // Filter to AmneziaWG: only the WG row is shown.
      await tester.tap(find.text('AmneziaWG'));
      await tester.pumpAndSettle();
      expect(find.text('Office WG'), findsOneWidget);
      expect(find.text('Germany sub'), findsNothing);

      // Open the WG row's overflow menu and pick Delete, then confirm.
      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      // The confirmation names the profile being removed.
      expect(find.textContaining('Office WG'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Only the WG profile is gone from the controller...
      expect(profiles.profiles.map((p) => p.id), <String>['s1', 's2']);
      // ...and the subscriptions are visible again: the stale filter
      // collapsed to All instead of hiding everything.
      expect(find.text('Germany sub'), findsOneWidget);
      expect(find.text('Holland sub'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('cancelling the confirmation deletes nothing',
        (WidgetTester tester) async {
      final ProfilesController profiles = await _pumpServers(tester, <ProxyProfile>[
        _sub('s1', 'Germany sub'),
        _awg('w1', 'Office WG'),
      ]);
      await tester.tap(find.byIcon(Icons.more_vert_rounded).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(profiles.profiles.length, 2);
      await _teardown(tester);
    });

    testWidgets('rows are keyed by profile id', (WidgetTester tester) async {
      await _pumpServers(tester, <ProxyProfile>[
        _sub('s1', 'Germany sub'),
        _awg('w1', 'Office WG'),
      ]);
      expect(find.byKey(const ValueKey<String>('server-row-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('server-row-w1')), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('AmneziaWG entry guard', () {
    Future<void> openManualAdd(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.add_rounded).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter manually'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AmneziaWG'));
      await tester.pumpAndSettle();
    }

    testWidgets('garbage pasted as AmneziaWG is refused with a message',
        (WidgetTester tester) async {
      final ProfilesController profiles =
          await _pumpServers(tester, <ProxyProfile>[_sub('s1', 'Germany sub')]);
      await openManualAdd(tester);
      await tester.enterText(find.byType(TextField).last, 'hello this is a photo caption');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a WireGuard/AmneziaWG config'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget, reason: 'dialog stays open');
      expect(profiles.profiles.length, 1);
      await _teardown(tester);
    });

    testWidgets('a conf missing its Endpoint is refused with the reason',
        (WidgetTester tester) async {
      final ProfilesController profiles =
          await _pumpServers(tester, <ProxyProfile>[_sub('s1', 'Germany sub')]);
      await openManualAdd(tester);
      await tester.enterText(find.byType(TextField).last,
          '[Interface]\nPrivateKey = x\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = y\n');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('need PrivateKey, Address, PublicKey, Endpoint'),
          findsOneWidget);
      expect(profiles.profiles.length, 1);
      await _teardown(tester);
    });

    testWidgets('a real conf saves as an AmneziaWG profile',
        (WidgetTester tester) async {
      final ProfilesController profiles =
          await _pumpServers(tester, <ProxyProfile>[_sub('s1', 'Germany sub')]);
      await openManualAdd(tester);
      await tester.enterText(find.byType(TextField).last, _awg('w', 'w').uri);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(profiles.profiles.length, 2);
      expect(profiles.profiles.last.kind, ProxyKind.awg);
      await _teardown(tester);
    });
  });

  group('ProfilesController before prefs attach', () {
    test('an add made before prefs arrive survives the load', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'nova.profiles': ProxyProfile.encodeList(<ProxyProfile>[
          _sub('s1', 'Persisted sub'),
        ]),
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProfilesController c = ProfilesController();
      // Deep-link import lands before SharedPreferences resolved.
      c.add(_sub('s2', 'Deep-linked sub'));
      c.setActive('s2');
      expect(c.profiles.length, 1);

      c.attachPrefs(prefs);
      expect(c.profiles.map((p) => p.id), <String>['s1', 's2']);
      expect(c.activeId, 's2');
      // And it was persisted, so the next launch has both.
      expect(
        ProxyProfile.decodeList(prefs.getString('nova.profiles')!)
            .map((p) => p.id),
        <String>['s1', 's2'],
      );
    });

    test('a remove made before prefs arrive stays removed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'nova.profiles': ProxyProfile.encodeList(<ProxyProfile>[
          _sub('s1', 'Keep'),
          _awg('w1', 'Gone'),
        ]),
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProfilesController c = ProfilesController();
      c.remove('w1');
      c.attachPrefs(prefs);
      expect(c.profiles.map((p) => p.id), <String>['s1']);
      expect(
        ProxyProfile.decodeList(prefs.getString('nova.profiles')!)
            .map((p) => p.id),
        <String>['s1'],
      );
    });
  });
}
