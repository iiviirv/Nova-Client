import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
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
import 'package:nova_client/src/widgets/nova_button.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Aether editor, driven the way a person drives it.
///
/// Several of these cover conditional fields, which is where an editor quietly
/// lies: a transport shown for a protocol that is not carried over HTTP, or an
/// advanced setting still in effect on a screen that no longer shows it.
/// Another covers the only thing the screen actually produces, the link, end to
/// end through the profile store and back out through the parser other clients
/// share.
///
/// The rest cover what the tester in Iran hit. gool shipped with no way to find
/// a gateway, so a gool config saved with none and could not connect; and
/// nothing stopped any mode saving a config with an address nobody had checked.
/// Both are one rule now: Save waits for a gateway that carried traffic.

/// A search the test drives by hand, because the native core cannot be loaded
/// on a test host at all.
class _FakeSearch implements AetherGatewaySearch {
  _FakeSearch({this.coreAvailable = true});

  final bool coreAvailable;
  final Completer<AetherFindResult> _done = Completer<AetherFindResult>();
  ValueChanged<AetherSearchProgress>? _report;
  bool _cancelled = false;

  /// The options the screen asked to search with.
  AetherOptions? asked;

  @override
  bool get available => coreAvailable;

  @override
  bool get cancelled => _cancelled;

  @override
  void cancel() {
    _cancelled = true;
    if (!_done.isCompleted) {
      _done.complete(const AetherFindResult(
          endpoint: null,
          attempts: 1,
          rejected: <String>[],
          error: 'cancelled'));
    }
  }

  /// What a replacement search was told to skip, so a test can check that the
  /// address which just failed is not offered back.
  List<String> excluded = const <String>[];

  /// What a typed address was checked against, and what to answer.
  String? checked;
  bool addressIsGood = true;

  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async {
    checked = endpoint;
    return addressIsGood;
  }

  @override
  Future<AetherFindResult> run(
    AetherOptions options,
    ValueChanged<AetherSearchProgress> onProgress, {
    List<String> excludedFirst = const <String>[],
  }) {
    asked = options;
    excluded = excludedFirst;
    _report = onProgress;
    return _done.future;
  }

  void report(int attempt, {bool verifying = false, int ruledOut = 0}) =>
      _report!(AetherSearchProgress(
          attempt: attempt, verifying: verifying, ruledOut: ruledOut));

  void finish(AetherFindResult r) {
    if (!_done.isCompleted) _done.complete(r);
  }
}

late ProfilesController profiles;

/// Pumps the editor on a route of its own, so Save's pop has somewhere to go.
Future<void> _open(
  WidgetTester tester, {
  AetherGatewaySearch? search,
  /// Profiles already on the list, for the duplicate-name check.
  List<ProxyProfile> seed = const <ProxyProfile>[],
  /// The config being edited, when this is an edit rather than a new one.
  ProxyProfile? existing,
}) async {
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
            onPressed: () => Navigator.of(ctx).push<void>(
              MaterialPageRoute<void>(
                  builder: (_) =>
                      AetherEditorScreen(search: search, existing: existing)),
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

/// Taps a choice pill by its label.
Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
}

/// Everything below the protocol lives under Advanced, so most of these have
/// to open it first.
Future<void> _advanced(WidgetTester tester) => _choose(tester, 'Advanced');

/// Whether the Save button would do anything if it were tapped.
bool _saveEnabled(WidgetTester tester) =>
    tester
        .widget<NovaButton>(find.widgetWithText(NovaButton, 'Save'))
        .onPressed !=
    null;

/// What the name field holds. It is the first field on the screen in both
/// depths, and the only one in Simple.
String _nameField(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

/// Runs a search to a verified gateway, which is the only way to a save.
Future<void> _findGateway(WidgetTester tester, _FakeSearch search,
    {String endpoint = '188.114.97.3:2408'}) async {
  await tester.tap(find.text('Find a gateway now'));
  await tester.pump();
  search.finish(
      AetherFindResult(endpoint: endpoint, attempts: 1, rejected: const <String>[]));
  await tester.pumpAndSettle();
}

/// A saved Aether profile, for the seeded-list and edit cases.
ProxyProfile _aether(String id, String name, String link) => ProxyProfile(
      id: id,
      name: name,
      kind: ProxyKind.aether,
      uri: link,
      updatedAt: DateTime.now(),
    );

void main() {
  testWidgets('the transport is offered for MASQUE and nowhere else',
      (WidgetTester tester) async {
    await _open(tester);
    await _advanced(tester);

    // MASQUE is the default, so the transport is there on arrival.
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('HTTP/3'), findsOneWidget);
    expect(find.text('HTTP/2'), findsOneWidget);

    // WireGuard and gool are not carried over HTTP at all, so a transport
    // choice there would be a setting that changes nothing.
    await _choose(tester, 'WireGuard');
    expect(find.text('Transport'), findsNothing);
    expect(find.text('HTTP/3'), findsNothing);

    await _choose(tester, 'gool');
    expect(find.text('Transport'), findsNothing);

    await _choose(tester, 'MASQUE');
    expect(find.text('Transport'), findsOneWidget);
  });

  testWidgets('gool searches for a gateway like the other two',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    await _choose(tester, 'gool');
    expect(find.text('Find a gateway now'), findsOneWidget,
        reason: 'gool shipped with no search at all, so a gool config saved '
            'with no gateway and the dashboard said it had none');

    await _findGateway(tester, search, endpoint: '162.159.192.4:2408');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final ProxyProfile saved = profiles.profiles
        .firstWhere((ProxyProfile p) => p.kind == ProxyKind.aether);
    final AetherConfig? read = AetherConfig.parse(saved.uri);
    expect(read!.options.mode, AetherMode.gool);
    expect(read.gateway, '162.159.192.4:2408',
        reason: 'the core finds the inner hop itself, so one verified address '
            'is a gool config that connects');
  });

  testWidgets('Simple shows the protocol and the search, and nothing else',
      (WidgetTester tester) async {
    await _open(tester);

    // Card eyebrows are upper-cased in Latin, which is what is on screen.
    const List<String> advancedOnly = <String>[
      'Transport',
      'OBFUSCATION',
      'IP VERSION',
      'Scan mode',
      'Address and port',
    ];

    // The protocol and the search are the whole of Simple.
    expect(find.text('PROTOCOL'), findsOneWidget);
    expect(find.text('Find a gateway now'), findsOneWidget);

    for (final String hidden in advancedOnly) {
      expect(find.text(hidden), findsNothing,
          reason: '$hidden is an advanced setting and Simple offers none');
    }

    await _advanced(tester);
    for (final String shown in advancedOnly) {
      expect(find.text(shown), findsOneWidget);
    }
  });

  testWidgets('Simple puts back the settings it does not show',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    await _advanced(tester);
    await _choose(tester, 'HTTP/2');
    await _choose(tester, 'Ironclad');
    await _choose(tester, 'Simple');

    await _findGateway(tester, search);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final AetherConfig read = AetherConfig.parse(profiles.profiles
        .firstWhere((ProxyProfile p) => p.kind == ProxyKind.aether)
        .uri)!;
    expect(read.options.transport, AetherTransport.h3);
    expect(read.options.scan, AetherScan.balanced,
        reason: 'Simple says every other setting takes its default, so a '
            'choice it has hidden must not still be in force');
  });

  testWidgets('Save waits for a gateway that carried traffic',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    expect(_saveEnabled(tester), isFalse,
        reason: 'a config saved with no gateway cannot connect, which is what '
            'the tester was left holding');
    expect(find.textContaining('Save waits for a gateway'), findsOneWidget);

    await tester.tap(find.text('Find a gateway now'));
    await tester.pump();
    expect(_saveEnabled(tester), isFalse,
        reason: 'the running search is not an answer yet');

    search.finish(const AetherFindResult(
        endpoint: null,
        error: 'the tunnel did not carry traffic',
        attempts: 4,
        rejected: <String>[]));
    await tester.pumpAndSettle();
    expect(_saveEnabled(tester), isFalse,
        reason: 'a search that found nothing leaves nothing to save');
  });

  testWidgets('a verified gateway that a later change invalidates locks Save '
      'again', (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    await _findGateway(tester, search);
    expect(_saveEnabled(tester), isTrue);

    // A gateway proven over WireGuard says nothing about MASQUE.
    await _choose(tester, 'WireGuard');
    expect(_saveEnabled(tester), isFalse);
  });

  testWidgets('a new config is named after its protocol, numbered past a '
      'name already taken', (WidgetTester tester) async {
    await _open(tester, seed: <ProxyProfile>[
      _aether('a', 'MASQUE', 'aether://1.1.1.1:443?protocol=masque'),
      _aether('b', 'Gool', 'aether://1.1.1.2:443?protocol=gool'),
    ]);

    expect(_nameField(tester), 'MASQUE 2',
        reason: 'MASQUE is the default protocol and that name is taken');

    await _choose(tester, 'gool');
    expect(_nameField(tester), 'Gool 2');

    await _choose(tester, 'WireGuard');
    expect(_nameField(tester), 'WireGuard',
        reason: 'nothing is called WireGuard yet, so it needs no number');

    // Once the user types, the name is theirs.
    await tester.enterText(find.byType(TextField).first, 'Tehran');
    await _choose(tester, 'gool');
    expect(_nameField(tester), 'Tehran');
  });

  testWidgets('editing a saved config reopens it as it was',
      (WidgetTester tester) async {
    final ProxyProfile saved = _aether('z', 'Home WARP',
        'aether://188.114.97.3:2408?protocol=wg&scan=thorough&ip=both#Home%20WARP');
    await _open(tester, seed: <ProxyProfile>[saved], existing: saved);

    expect(find.text('Edit Aether config'), findsOneWidget);
    expect(_nameField(tester), 'Home WARP');
    // A gateway that was verified when it was saved does not cost another
    // three-minute search to rename.
    expect(_saveEnabled(tester), isTrue);
    expect(find.text('188.114.97.3:2408 carried traffic.'), findsOneWidget);
    // Opened at the depth that shows what it is made of, not one that hides it.
    expect(find.text('Thorough'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Home');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(profiles.profiles.where((ProxyProfile p) => p.kind == ProxyKind.aether),
        hasLength(1),
        reason: 'editing replaces the config, it does not add a second one');
    final ProxyProfile after = profiles.profiles
        .firstWhere((ProxyProfile p) => p.kind == ProxyKind.aether);
    expect(after.id, 'z');
    expect(after.name, 'Home');
    expect(AetherConfig.parse(after.uri)!.gateway, '188.114.97.3:2408');
  });

  testWidgets('a saved config is a link the shared parser reads back',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);
    await _advanced(tester);

    await tester.enterText(find.byType(TextField).first, 'Home WARP');
    await _choose(tester, 'HTTP/2');
    await _choose(tester, 'Both');
    await _choose(tester, 'Thorough');
    await _findGateway(tester, search);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final ProxyProfile saved = profiles.profiles
        .firstWhere((ProxyProfile p) => p.kind == ProxyKind.aether);
    expect(saved.name, 'Home WARP');

    final AetherConfig? read = AetherConfig.parse(saved.uri);
    expect(read, isNotNull,
        reason: 'a config that does not parse back is one no client can '
            'import, including this one');
    expect(read!.name, 'Home WARP');
    expect(read.options.mode, AetherMode.masque);
    expect(read.options.transport, AetherTransport.h2);
    expect(read.options.ip, AetherIpMode.both);
    expect(read.options.scan, AetherScan.thorough);
    // Untouched, so it stays null: "let the core choose" is a real state and
    // not the same as picking whatever the first profile happens to be.
    expect(read.options.noize, isNull);
  });

  testWidgets('a running search says which address it is on',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);
    await _advanced(tester);

    await tester.tap(find.text('Find a gateway now'));
    await tester.pump();

    expect(find.text('Address 1: looking for one'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    search.report(2, verifying: true, ruledOut: 1);
    await tester.pump();
    expect(find.text('Address 2: checking that it carries traffic'),
        findsOneWidget);
    expect(find.text('1 ruled out so far'), findsOneWidget,
        reason: 'the count is what explains a long wait');

    // Deliberately not the address the empty field hints at, so "the field
    // holds it now" cannot pass on the placeholder.
    search.finish(const AetherFindResult(
        endpoint: '188.114.97.3:2408', attempts: 2, rejected: <String>['x']));
    await tester.pumpAndSettle();

    expect(find.text('188.114.97.3:2408 carried traffic.'), findsOneWidget);
    // The verified address is kept, which is the whole difference from a scan
    // that hands back something unproven.
    expect(find.text('188.114.97.3:2408'), findsOneWidget);
  });

  testWidgets('a search can be stopped', (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    await tester.tap(find.text('Find a gateway now'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Search stopped.'), findsOneWidget);
    expect(find.text('Find a gateway now'), findsOneWidget);
  });

  testWidgets('a failed search says so, and what it ruled out',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _open(tester, search: search);

    await tester.tap(find.text('Find a gateway now'));
    await tester.pump();
    search.finish(const AetherFindResult(
      endpoint: null,
      error: 'the tunnel did not carry traffic',
      attempts: 4,
      rejected: <String>['1.1.1.1:443', '2.2.2.2:443'],
    ));
    await tester.pumpAndSettle();

    expect(
        find.text(
            'No gateway carried traffic: the tunnel did not carry traffic'),
        findsOneWidget);
    expect(find.text('2 ruled out so far'), findsOneWidget);
  });

  testWidgets('a build with no core says so instead of offering the button',
      (WidgetTester tester) async {
    await _open(tester, search: _FakeSearch(coreAvailable: false));

    expect(find.text('Find a gateway now'), findsNothing);
    expect(
        find.textContaining('This build ships no Aether core'), findsOneWidget);
  });
}
