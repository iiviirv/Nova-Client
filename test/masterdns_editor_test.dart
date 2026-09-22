import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/masterdns_editor_screen.dart';
import 'package:nova_client/src/features/servers/servers_body.dart';
import 'package:nova_client/src/features/servers/servers_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_button.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The MasterDNS editor, and the two ways into it from the add sheet.
///
/// What these guard is the stored profile. The connect path reads a MasterDNS
/// profile with `parseLink` and nothing else, so a profile holding pasted JSON,
/// or a link with no resolvers in it, is a server on the list that can never
/// connect and says nothing about why.

late ProfilesController profiles;

/// Pumps a home screen whose one button runs [onOpen], so the editor lands on
/// a route of its own and Save's pop has somewhere to go.
Future<void> _pump(
  WidgetTester tester,
  Future<void> Function(BuildContext) onOpen, {
  List<ProxyProfile> seed = const <ProxyProfile>[],
  Map<String, Object> prefsSeed = const <String, Object>{},
}) async {
  // Tall enough that the whole editor is built at once: a ListView does not
  // build what is off screen.
  tester.view.physicalSize = const Size(420, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefsSeed);
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  profiles = ProfilesController()..attachPrefs(prefs)..selectTab(false);
  for (final ProxyProfile p in seed) {
    profiles.add(p);
  }
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
            onPressed: () => onOpen(ctx),
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

Future<void> _openEditor(WidgetTester tester,
        {ProxyProfile? existing, List<ProxyProfile> seed = const []}) =>
    _pump(
      tester,
      (BuildContext ctx) => Navigator.of(ctx).push<void>(
          MaterialPageRoute<void>(
              builder: (_) => MasterDnsEditorScreen(existing: existing))),
      seed: seed,
    );

Finder _field(String label) => find.widgetWithText(TextField, label);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

Future<void> _type(WidgetTester tester, String label, String value) async {
  await tester.enterText(_field(label), value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

bool _saveEnabled(WidgetTester tester) =>
    tester
        .widget<NovaButton>(find.widgetWithText(NovaButton, 'Save'))
        .onPressed !=
    null;

/// The shape another client shows and shares.
const String _friendlyJson = '{"domain":"t.example.test",'
    '"key":"0123456789abcdef","method":5,'
    '"resolvers":["9.9.9.9","1.0.0.1"]}';

/// A sing-box config: also a JSON object, and never a MasterDNS one.
const String _singbox = '{"log":{"level":"warn"},'
    '"outbounds":[{"type":"vless","tag":"proxy","server":"a.example.test",'
    '"server_port":443,"uuid":"b0c2e0a1-0000-4000-8000-000000000000"}]}';

/// What the engine's sample config looks like, which has no resolvers.
const String _toml = 'DOMAINS = ["t.example.test"]\n'
    'ENCRYPTION_KEY = "0123456789abcdef"\n'
    'DATA_ENCRYPTION_METHOD = 2\n';

void main() {
  testWidgets('the key is hidden until asked for', (WidgetTester tester) async {
    await _openEditor(tester);

    expect(tester.widget<TextField>(_field('Encryption key')).obscureText,
        isTrue,
        reason: 'the key is a credential and should not be on screen by '
            'default');

    await tester.tap(find.byTooltip('Show key'));
    await tester.pump();
    expect(tester.widget<TextField>(_field('Encryption key')).obscureText,
        isFalse);

    await tester.tap(find.byTooltip('Hide key'));
    await tester.pump();
    expect(tester.widget<TextField>(_field('Encryption key')).obscureText,
        isTrue);
  });

  testWidgets('Save refuses a config with something missing, and says what',
      (WidgetTester tester) async {
    await _openEditor(tester);

    // A new config starts with the public resolvers and nothing else.
    expect(_text(tester, 'One per line'), '8.8.8.8\n1.1.1.1\n208.67.222.222');
    expect(_saveEnabled(tester), isFalse);
    expect(find.text('Save waits for the tunnel domain.'), findsOneWidget);

    await _type(tester, 'Domain', 't.example.test');
    expect(_saveEnabled(tester), isFalse);
    expect(find.textContaining('Save waits for the encryption key.'),
        findsOneWidget);

    await _type(tester, 'Encryption key', 'secret');
    expect(_saveEnabled(tester), isTrue);
    expect(find.textContaining('Save waits'), findsNothing);

    await _type(tester, 'One per line', '  \n ');
    expect(_saveEnabled(tester), isFalse);
    expect(find.text('Save waits for at least one resolver.'), findsOneWidget);

    // Tapping a disabled button does nothing, and nothing was stored.
    await tester.tap(find.widgetWithText(NovaButton, 'Save'));
    await tester.pumpAndSettle();
    expect(profiles.profiles.where((ProxyProfile p) =>
        p.kind == ProxyKind.masterdns), isEmpty);

    // The public resolvers are one tap away once the box is empty.
    await _tap(tester, 'Use public resolvers');
    expect(_saveEnabled(tester), isTrue);

    // With no encryption a key means nothing, so none is asked for.
    await _type(tester, 'Encryption key', '');
    expect(_saveEnabled(tester), isFalse);
    await _tap(tester, 'None');
    expect(_field('Encryption key'), findsNothing);
    expect(_saveEnabled(tester), isTrue);
  });

  testWidgets('Fields and Text carry the same config across',
      (WidgetTester tester) async {
    await _openEditor(tester);
    await _type(tester, 'Domain', 'a.example.test, b.example.test');
    await _type(tester, 'Encryption key', 'k1');
    await _tap(tester, 'AES-256-GCM');

    await _tap(tester, 'Text');
    final MasterDnsConfig shown =
        MasterDnsConfig.parseText(_text(tester, 'JSON or TOML'))!;
    expect(shown.domains, <String>['a.example.test', 'b.example.test']);
    expect(shown.key, 'k1');
    expect(shown.method, MasterDnsMethod.aes256);
    expect(shown.resolvers, <String>['8.8.8.8', '1.1.1.1', '208.67.222.222']);

    // An edit in the text comes back to the fields.
    await _type(tester, 'JSON or TOML',
        '{"domain":"c.example.test","key":"k2","method":2,'
        '"resolvers":["9.9.9.9"]}');
    await _tap(tester, 'Fields');
    expect(_text(tester, 'Domain'), 'c.example.test');
    expect(_text(tester, 'Encryption key'), 'k2');
    expect(_text(tester, 'One per line'), '9.9.9.9');
    await _tap(tester, 'Text');
    expect(
        MasterDnsConfig.parseText(_text(tester, 'JSON or TOML'))!.method,
        MasterDnsMethod.chacha20);

    // Text that is not a config keeps the person on Text, with what they
    // typed still there, and the fields untouched.
    await _type(tester, 'JSON or TOML', 'not a config');
    await _tap(tester, 'Fields');
    expect(find.textContaining('Nova cannot read this'), findsOneWidget);
    expect(_text(tester, 'JSON or TOML'), 'not a config');
    expect(_saveEnabled(tester), isFalse);

    // Clearing the box is the way back, and the fields are as they were.
    await _type(tester, 'JSON or TOML', '');
    await _tap(tester, 'Fields');
    expect(_text(tester, 'Domain'), 'c.example.test');
  });

  testWidgets('pasted MasterDNS JSON is stored as a link, not as JSON',
      (WidgetTester tester) async {
    await _pump(tester,
        (BuildContext ctx) => showAddServerDialog(ctx, prefill: _friendlyJson));

    // The editor, not the generic add dialog.
    expect(find.byType(MasterDnsEditorScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(_text(tester, 'Domain'), 't.example.test');

    await tester.tap(find.widgetWithText(NovaButton, 'Save'));
    await tester.pumpAndSettle();

    final List<ProxyProfile> saved = profiles.profiles
        .where((ProxyProfile p) => p.kind == ProxyKind.masterdns)
        .toList();
    expect(saved, hasLength(1));
    expect(saved.single.uri, startsWith('masterdns://'));
    final MasterDnsConfig back = MasterDnsConfig.parseLink(saved.single.uri)!;
    expect(back.domains, <String>['t.example.test']);
    expect(back.key, '0123456789abcdef');
    expect(back.method, MasterDnsMethod.aes256);
    expect(back.resolvers, <String>['9.9.9.9', '1.0.0.1']);
  });

  testWidgets('MasterDNS JSON typed into the add dialog goes to the editor',
      (WidgetTester tester) async {
    await _pump(tester, (BuildContext ctx) => showAddServerDialog(ctx));
    expect(find.byType(AlertDialog), findsOneWidget);

    final Finder fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'Typed DNS');
    await tester.enterText(fields.at(1), _friendlyJson);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.byType(MasterDnsEditorScreen), findsOneWidget);
    expect(_text(tester, 'Name'), 'Typed DNS');
    // Nothing is stored until the editor saves, and never as the raw text.
    expect(
        profiles.profiles.where((ProxyProfile p) =>
            p.kind == ProxyKind.masterdns || p.uri.startsWith('{')),
        isEmpty);
  });

  testWidgets('an unreadable MasterDNS link is refused, not stored',
      (WidgetTester tester) async {
    await _pump(tester, (BuildContext ctx) => showAddServerDialog(ctx));
    final Finder fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(1), 'masterdns://not-base64-at-all!');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(profiles.profiles.where((ProxyProfile p) =>
        p.kind == ProxyKind.masterdns), isEmpty);
    expect(find.textContaining('cannot read this MasterDNS link'),
        findsOneWidget);
  });

  testWidgets('the add sheet shows the MasterDNS entry in full on a phone',
      (WidgetTester tester) async {
    await _pump(tester, (BuildContext ctx) => showAddConfigSheet(ctx));
    // A common phone height. The sheet used to be capped at 9/16 of it.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    final Rect row = tester.getRect(find.text('Add a MasterDNS tunnel'));
    expect(row.bottom, lessThanOrEqualTo(844));
    await tester.tap(find.text('Add a MasterDNS tunnel'));
    await tester.pumpAndSettle();
    expect(find.byType(MasterDnsEditorScreen), findsOneWidget);
  });

  testWidgets('pasted engine TOML opens with no resolvers and cannot save yet',
      (WidgetTester tester) async {
    await _pump(
        tester, (BuildContext ctx) => showAddServerDialog(ctx, prefill: _toml));

    expect(find.byType(MasterDnsEditorScreen), findsOneWidget);
    expect(_text(tester, 'One per line'), isEmpty,
        reason: 'the engine format cannot carry resolvers, and the person '
            'has to see that rather than get defaults they did not choose');
    expect(_saveEnabled(tester), isFalse);
    expect(find.text('Save waits for at least one resolver.'), findsOneWidget);
  });

  testWidgets('a pasted sing-box config is not taken for MasterDNS',
      (WidgetTester tester) async {
    expect(detectProfileKind(_singbox), ProxyKind.singboxConfig);
    expect(detectProfileKind(_friendlyJson), ProxyKind.masterdns);
    expect(detectProfileKind(_toml), ProxyKind.masterdns);

    await _pump(tester,
        (BuildContext ctx) => showAddServerDialog(ctx, prefill: _singbox));
    expect(find.byType(MasterDnsEditorScreen), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('Edit on a MasterDNS row opens this editor',
      (WidgetTester tester) async {
    final ProxyProfile saved = ProxyProfile(
      id: 'dns-2',
      name: 'Row DNS',
      kind: ProxyKind.masterdns,
      uri: const MasterDnsConfig(
        domains: <String>['row.example.test'],
        key: 'k',
        resolvers: <String>['8.8.8.8'],
      ).toLink(),
      updatedAt: DateTime(2026),
    );
    // The list itself, not the editor, is what is under test here, so the
    // editor is reached the way a person reaches it.
    await _pump(
      tester,
      (BuildContext ctx) => Navigator.of(ctx).push<void>(
          MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: ServersScreen()))),
      seed: <ProxyProfile>[saved],
      // Not a fresh install, so the free list does not add rows above it.
      prefsSeed: <String, Object>{ProfilesController.kFreeSeededKey: true},
    );
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit').last);
    await tester.pumpAndSettle();

    expect(find.byType(MasterDnsEditorScreen), findsOneWidget,
        reason: 'the generic edit dialog would show the base64 link');
    expect(_text(tester, 'Domain'), 'row.example.test');
  });

  testWidgets('editing a saved config keeps its id',
      (WidgetTester tester) async {
    final String link = const MasterDnsConfig(
      domains: <String>['old.example.test'],
      key: 'k',
      resolvers: <String>['8.8.8.8'],
      name: 'Home DNS',
    ).toLink();
    final ProxyProfile saved = ProxyProfile(
      id: 'dns-1',
      name: 'Home DNS',
      kind: ProxyKind.masterdns,
      uri: link,
      updatedAt: DateTime(2026),
    );
    await _openEditor(tester, existing: saved, seed: <ProxyProfile>[saved]);

    expect(find.text('Edit MasterDNS config'), findsOneWidget);
    expect(_text(tester, 'Name'), 'Home DNS');
    expect(_text(tester, 'Domain'), 'old.example.test');
    // A saved config shows its own resolvers, not the defaults.
    expect(_text(tester, 'One per line'), '8.8.8.8');

    await _type(tester, 'Domain', 'new.example.test');
    await tester.tap(find.widgetWithText(NovaButton, 'Save'));
    await tester.pumpAndSettle();

    final List<ProxyProfile> dns = profiles.profiles
        .where((ProxyProfile p) => p.kind == ProxyKind.masterdns)
        .toList();
    expect(dns, hasLength(1));
    expect(dns.single.id, 'dns-1');
    expect(MasterDnsConfig.parseLink(dns.single.uri)!.domains,
        <String>['new.example.test']);
  });
}
