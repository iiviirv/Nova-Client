import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';
import 'package:nova_client/src/features/servers/aether_search_widgets.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_app_shell.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The offer to replace a dead Aether gateway.
///
/// Field report from Iran: the tunnel came up carrying nothing, and the notice
/// said "look for another one?" with no way to answer. He waited about two
/// minutes and then rebuilt the config by hand, four times. The detection and
/// the remedy both existed; nothing joined them.
///
/// So these are about the join: that the question can be answered, that the
/// answer reaches the controller, that a search which finds nothing says
/// something different from the failure that started it, and that ignoring the
/// question is taken as an answer rather than asked again.

const String _staleMessage =
    'This connection came up but nothing is getting through. Its Cloudflare '
    'gateway may have stopped answering since it was checked.';

/// A controller stuck where the tester was: connected, carrying nothing.
class _StaleProxy extends ProxyController {
  _StaleProxy(this._active);

  ProxyProfile? _active;
  DateTime _since = DateTime(2026, 9, 15, 10);

  /// How many replacements were asked for, and what was handed over.
  int replaceCalls = 0;
  ProxyProfile? replacedFor;

  /// Held open so a test can watch the wait, then decide how it ends.
  Completer<bool>? pending;

  @override
  ProxyConnectionState get state => ProxyConnectionState.connected;

  @override
  DateTime? get connectedSince => _since;

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
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> replaceAetherGateway(ProxyProfile profile) {
    replaceCalls++;
    replacedFor = profile;
    gatewaySearch.value = (replacing: true, progress: const AetherSearchProgress(attempt: 1, verifying: false, ruledOut: 0));
    return (pending = Completer<bool>()).future.whenComplete(() => gatewaySearch.value = null);
  }

  /// What the probe loop does when it gives up.
  void raise(ProxyNotice code) => notice.value = code;

  /// A reconnect: the same profile on a new connection.
  void reconnected() => _since = _since.add(const Duration(minutes: 5));
}

ProxyProfile _aether() => ProxyProfile(
      id: 'a1',
      name: 'WireGuard',
      kind: ProxyKind.aether,
      uri: 'aether://188.114.97.3:2408?protocol=wg&scan=balanced&ip=v4',
      updatedAt: DateTime(2026, 9, 1),
    );

ProxyProfile _vless() => ProxyProfile(
      id: 'v1',
      name: 'Germany',
      kind: ProxyKind.vless,
      uri: 'vless://id@example.invalid:443?type=ws&security=tls#Germany',
      updatedAt: DateTime(2026, 9, 1),
    );

/// The shell builds every tab at once, and the Servers tab reads saved panel
/// credentials out of the platform keychain. There is no keychain on a test
/// host, so the plugin throws from an async gap and lands on whichever pump
/// happens to be running. Answered with nothing, which is the truth here.
void _silenceSecureStorage() {
  const MethodChannel channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
    if (call.method == 'readAll') return <String, String>{};
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
}

Future<_StaleProxy> _pumpShell(
    WidgetTester tester, ProxyProfile profile) async {
  _silenceSecureStorage();
  // Tall enough that a snackbar arriving over the connected dashboard does
  // not squeeze the hero into an overflow, which would fail the test for a
  // reason that has nothing to do with the offer.
  tester.view.physicalSize = const Size(400, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{
    ProfilesController.kFreeSeededKey: true,
  });
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ProfilesController profiles = ProfilesController()..attachPrefs(prefs);
  profiles.add(profile);
  profiles.setActive(profile.id);
  final _StaleProxy proxy = _StaleProxy(profile);
  final RelayController relay = RelayController();

  await tester.pumpWidget(NovaScope(
    theme: ThemeController()..attachPrefs(prefs),
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
      locale: const Locale('en'),
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
      home: const MediaQuery(
        // The bottom bar gives each destination 49dp and the test host has no
        // real font loaded, so the fallback's taller label metrics overflow a
        // nav cell that fits comfortably in the shipped typeface. Scaling the
        // text down keeps that pre-existing tightness out of a test about the
        // gateway offer.
        data: MediaQueryData(textScaler: TextScaler.linear(0.8)),
        child: NovaAppShell(),
      ),
    ),
  ));
  await tester.pump();
  return proxy;
}

/// Lets a snackbar finish arriving or leaving.
///
/// Not pumpAndSettle: the dashboard runs an uptime clock while connected, so
/// there is always another frame coming and settling never finishes.
Future<void> _snack(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Tears the tree down so the dashboard's uptime ticker is gone before the
/// test ends.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('a stale gateway is offered a replacement, not just described',
      (WidgetTester tester) async {
    final _StaleProxy proxy = await _pumpShell(tester, _aether());

    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);

    expect(find.text(_staleMessage), findsOneWidget);
    expect(find.text('Find another'), findsOneWidget,
        reason: 'a message that asks a question with no way to answer it is '
            'worse than no message');
    await _teardown(tester);
  });

  testWidgets('accepting asks the controller for another gateway',
      (WidgetTester tester) async {
    final ProxyProfile profile = _aether();
    final _StaleProxy proxy = await _pumpShell(tester, profile);

    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    await tester.tap(find.text('Find another'));
    await _snack(tester);

    expect(proxy.replaceCalls, 1);
    expect(proxy.replacedFor?.id, profile.id,
        reason: 'the replacement is for the config that is connected');
    // The search runs for minutes, so the wait has to look like work. It is
    // the readout that says so now: a bar that never fills was what the
    // tester who cancelled a healthy search had been watching.
    expect(find.text('Finding a replacement gateway'),
        findsOneWidget);
    expect(find.byType(AetherProgressLines), findsOneWidget);

    proxy.pending!.complete(true);
    await _snack(tester);
    expect(find.text('Connected through a new gateway.'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('a replacement that finds nothing says something different',
      (WidgetTester tester) async {
    final _StaleProxy proxy = await _pumpShell(tester, _aether());

    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    await tester.tap(find.text('Find another'));
    await _snack(tester);
    proxy.pending!.complete(false);
    await _snack(tester);

    expect(find.textContaining('No other gateway answered either'),
        findsOneWidget);
    expect(find.text(_staleMessage), findsNothing,
        reason: 'no gateway anywhere is a different fact from this gateway '
            'having gone stale, and repeating the first would hide the second');
    await _teardown(tester);
  });

  testWidgets('a second offer is not made while one is being answered',
      (WidgetTester tester) async {
    final _StaleProxy proxy = await _pumpShell(tester, _aether());

    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    await tester.tap(find.text('Find another'));
    await _snack(tester);

    // The controller gives up again while the first search is still running.
    proxy.reconnected();
    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);

    expect(find.text(_staleMessage), findsNothing,
        reason: 'a second search would run behind the first');
    expect(proxy.replaceCalls, 1);

    proxy.pending!.complete(false);
    await _snack(tester);
    await _teardown(tester);
  });

  testWidgets('ignoring the offer is an answer, and it is not asked again',
      (WidgetTester tester) async {
    final _StaleProxy proxy = await _pumpShell(tester, _aether());

    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    expect(find.text(_staleMessage), findsOneWidget);

    // Left unanswered until it goes away. Dismissed by hand here because the
    // snackbar's own timeout does not run on a pumped test clock, but the
    // point is the same: the question left the screen without an answer.
    ScaffoldMessenger.of(tester.element(find.byType(NovaAppShell)))
        .hideCurrentSnackBar();
    await _snack(tester);
    expect(find.text(_staleMessage), findsNothing);

    // The probe loop gives up again on the same connection.
    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    expect(find.text(_staleMessage), findsNothing,
        reason: 'one connection asks once: a question re-asked every time the '
            'probe loop gives up is nagging, not an offer');

    // A new connection is a new question, so a gateway that goes stale after a
    // reconnect is still offered a replacement.
    proxy.reconnected();
    proxy.raise(ProxyNotice.aetherGatewayStale);
    await _snack(tester);
    expect(find.text(_staleMessage), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('a profile that is not Aether keeps its plain message',
      (WidgetTester tester) async {
    final _StaleProxy proxy = await _pumpShell(tester, _vless());

    proxy.raise(ProxyNotice.pinnedExitNoTraffic);
    await _snack(tester);

    expect(find.textContaining('no traffic is getting through'),
        findsOneWidget);
    expect(find.text('Find another'), findsNothing,
        reason: 'only an Aether gateway can be swapped without the user '
            'choosing a different server');
    await _teardown(tester);
  });
}
