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
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Aether editor, driven the way a person drives it.
///
/// Two of these cover conditional fields, which is where an editor quietly
/// lies: a transport shown for a protocol that is not carried over HTTP, or a
/// gool config offered one address when it dials two. The third covers the only
/// thing the screen actually produces, the link, end to end through the profile
/// store and back out through the parser other clients share.
///
/// The scan tests cover the point of the screen: a wait that says which address
/// it is on, and a Cancel that stops it.

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

/// Taps a choice pill by its label.
Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
}

void main() {
  testWidgets('the transport is offered for MASQUE and nowhere else',
      (WidgetTester tester) async {
    await _open(tester);

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

  testWidgets('gool asks for two hops instead of one address',
      (WidgetTester tester) async {
    await _open(tester);

    // One address for the one-hop protocols.
    expect(find.text('Address and port'), findsOneWidget);
    expect(find.text('Outer hop'), findsNothing);

    await _choose(tester, 'gool');
    expect(find.text('Outer hop'), findsOneWidget);
    expect(find.text('Inner hop'), findsOneWidget);
    expect(find.text('Address and port'), findsNothing,
        reason: 'gool dials two hops: a single address field would be a lie '
            'about what the config needs');
  });

  testWidgets('a saved config is a link the shared parser reads back',
      (WidgetTester tester) async {
    await _open(tester);

    await tester.enterText(find.byType(TextField).first, 'Home WARP');
    await _choose(tester, 'HTTP/2');
    await _choose(tester, 'Both');
    await _choose(tester, 'Thorough');
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
