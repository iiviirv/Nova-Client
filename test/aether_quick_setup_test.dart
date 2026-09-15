import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/dashboard/aether_quick_setup_card.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The dashboard shortcut: one tap that ends in a connection.
///
/// The two things that make it worth having are the two things tested here. It
/// does the whole job rather than opening a form, and it leaves once the user
/// has an Aether config that can connect, so the home screen is not carrying a
/// permanent advertisement.

/// A search the test drives by hand. The native core cannot be loaded on a
/// test host at all.
class _FakeSearch implements AetherGatewaySearch {
  final Completer<AetherFindResult> _done = Completer<AetherFindResult>();
  bool _cancelled = false;
  AetherOptions? asked;

  @override
  bool get available => true;

  @override
  bool get cancelled => _cancelled;

  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async =>
      true;

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

  @override
  Future<AetherFindResult> run(
    AetherOptions options,
    ValueChanged<AetherSearchProgress> onProgress, {
    List<String> excludedFirst = const <String>[],
  }) {
    asked = options;
    return _done.future;
  }

  void finish(AetherFindResult r) {
    if (!_done.isCompleted) _done.complete(r);
  }
}

/// A proxy that records rather than tunnels. The mock controller runs a live
/// traffic ticker, which would outlive the test.
class _RecordingProxy extends ProxyController {
  _RecordingProxy({this.state = ProxyConnectionState.disconnected});

  ProxyProfile? _active;
  int connects = 0;

  @override
  final ProxyConnectionState state;

  @override
  TrafficStats get traffic => TrafficStats.zero;

  @override
  ProxyProfile? get activeProfile => _active;

  @override
  String? get lastError => null;

  @override
  void selectProfile(ProxyProfile? profile) {
    _active = profile;
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    connects += 1;
  }

  @override
  Future<void> disconnect() async {}
}

late ProfilesController profiles;
late _RecordingProxy _proxy;

ProxyProfile _aether(String id, String name, String link) => ProxyProfile(
      id: id,
      name: name,
      kind: ProxyKind.aether,
      uri: link,
      updatedAt: DateTime.now(),
    );

Future<void> _pump(
  WidgetTester tester, {
  AetherGatewaySearch? search,
  List<ProxyProfile> seed = const <ProxyProfile>[],
  ProxyConnectionState proxyState = ProxyConnectionState.disconnected,
}) async {
  tester.view.physicalSize = const Size(420, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  profiles = ProfilesController()..attachPrefs(prefs);
  for (final ProxyProfile p in seed) {
    profiles.add(p);
  }
  _proxy = _RecordingProxy(state: proxyState);
  final RelayController relay = RelayController();

  await tester.pumpWidget(NovaScope(
    theme: ThemeController()..attachPrefs(prefs),
    proxy: _proxy,
    connInfo: ConnInfoController(_proxy),
    profiles: profiles,
    radar: RadarController()..attachPrefs(prefs),
    settings: SettingsController(prefs: prefs),
    appRouting: AppRouting(),
    vps: VpsController(profiles, _proxy, relay),
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
        body: SingleChildScrollView(
            child: AetherQuickSetupCard(search: search)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the shortcut is offered when nothing here can build a tunnel',
      (WidgetTester tester) async {
    await _pump(tester, search: _FakeSearch());

    expect(find.text('Build a WARP tunnel'), findsOneWidget);
    expect(find.text('Build it and connect'), findsOneWidget);
    // The search runs for minutes, and a button that looks instant and then
    // hangs teaches people the feature is broken.
    expect(find.textContaining('a few minutes'), findsOneWidget);
  });

  testWidgets('the shortcut leaves once a working Aether config exists',
      (WidgetTester tester) async {
    await _pump(tester, search: _FakeSearch(), seed: <ProxyProfile>[
      _aether('a', 'WireGuard', 'aether://188.114.97.3:2408?protocol=wg'),
    ]);

    expect(find.text('Build a WARP tunnel'), findsNothing,
        reason: 'a permanent card for something the user already has is '
            'clutter on the one screen they use most');
  });

  testWidgets('the shortcut stays out of the way while a tunnel is up',
      (WidgetTester tester) async {
    await _pump(tester,
        search: _FakeSearch(),
        proxyState: ProxyConnectionState.connected);

    expect(find.text('Build a WARP tunnel'), findsNothing,
        reason: 'another way out is an offer for someone who has not got out');
  });

  testWidgets('a config saved with no gateway does not count as a working one',
      (WidgetTester tester) async {
    await _pump(tester, search: _FakeSearch(), seed: <ProxyProfile>[
      _aether('a', 'Gool', 'aether://?protocol=gool'),
    ]);

    expect(find.text('Build a WARP tunnel'), findsOneWidget,
        reason: 'a gateway-less config connects to nothing, so the offer to '
            'build one that works still stands');
  });

  testWidgets('one tap searches, saves and connects',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _pump(tester, search: search);

    await tester.tap(find.text('Build it and connect'));
    await tester.pump();
    expect(find.text('Address 1: looking for one'), findsOneWidget,
        reason: 'the wait is spent saying what is happening, not on a spinner');

    search.finish(const AetherFindResult(
        endpoint: '188.114.97.3:2408', attempts: 1, rejected: <String>[]));
    await tester.pumpAndSettle();

    final ProxyProfile saved = profiles.profiles
        .firstWhere((ProxyProfile p) => p.kind == ProxyKind.aether);
    expect(AetherConfig.parse(saved.uri)!.gateway, '188.114.97.3:2408');
    // WireGuard, because the tester's MASQUE searches took about three minutes
    // each and this path is for someone who wants it over with.
    expect(search.asked!.mode, AetherMode.masque,
        reason: 'the one-tap button must build the protocol confirmed working '
            'for users in Iran; WireGuard connects there and carries nothing');
    expect(profiles.activeId, saved.id);
    expect(_proxy.activeProfile?.id, saved.id);
    expect(_proxy.connects, 1,
        reason: 'the ask was one tap to a connection, not one tap to a form');
  });

  testWidgets('a search that found nothing says so and offers another go',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch();
    await _pump(tester, search: search);

    await tester.tap(find.text('Build it and connect'));
    await tester.pump();
    search.finish(const AetherFindResult(
        endpoint: null,
        error: 'the tunnel did not carry traffic',
        attempts: 4,
        rejected: <String>[]));
    await tester.pumpAndSettle();

    expect(
        find.text(
            'No gateway carried traffic: the tunnel did not carry traffic'),
        findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(profiles.profiles.any((ProxyProfile p) => p.kind == ProxyKind.aether),
        isFalse,
        reason: 'nothing to save: a config with no gateway is the bug');
  });
}
