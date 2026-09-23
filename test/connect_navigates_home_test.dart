import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
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
import 'package:nova_client/src/widgets/nova_connect_button.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Field report: tapping Connect while reading the Servers list left the user
/// on the list. The gateway search reports its progress on Home, so a search
/// that runs for a minute looked like the button had done nothing at all.

class _Proxy extends ProxyController {
  _Proxy(this._active, this._state);
  ProxyProfile? _active;
  // Set at construction rather than through connect(), so reaching 'connected'
  // never notifies. ConnInfoController starts a run of warmup timers the moment
  // it sees that transition, and this test is about navigation, not probes.
  ProxyConnectionState _state;
  final List<String> calls = <String>[];

  @override
  ProxyConnectionState get state => _state;
  @override
  ProxyProfile? get activeProfile => _active;
  @override
  TrafficStats get traffic => TrafficStats.zero;
  @override
  String? get lastError => null;
  @override
  void selectProfile(ProxyProfile? p) => _active = p;
  @override
  Future<void> connect() async {
    calls.add('connect');
    // Stops short of 'connected' on purpose: see the field note above.
    _state = ProxyConnectionState.connecting;
    notifyListeners();
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _state = ProxyConnectionState.disconnected;
    notifyListeners();
  }
}

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

/// The shell shows one tab at a time out of an IndexedStack, so the index it
/// is showing is the honest answer to "which tab is the user looking at".
int _tab(WidgetTester tester) =>
    tester.widget<IndexedStack>(find.byType(IndexedStack).first).index ?? -1;

Future<_Proxy> _pumpShell(WidgetTester tester,
    {ProxyConnectionState initial = ProxyConnectionState.disconnected}) async {
  _silenceSecureStorage();
  tester.view.physicalSize = const Size(400, 1100);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{
    ProfilesController.kFreeSeededKey: true,
  });
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ProfilesController profiles = ProfilesController()..attachPrefs(prefs);
  final ProxyProfile profile = ProxyProfile(
    id: 'a1',
    name: 'WireGuard',
    kind: ProxyKind.aether,
    uri: 'aether://188.114.97.3:2408?protocol=wg&scan=balanced&ip=v4',
    updatedAt: DateTime(2026, 9, 1),
  );
  profiles.add(profile);
  profiles.setActive(profile.id);
  final _Proxy proxy = _Proxy(profile, initial);
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
        data: MediaQueryData(textScaler: TextScaler.linear(0.8)),
        child: NovaAppShell(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return proxy;
}

void main() {
  testWidgets('connecting from the Servers tab moves to Home, where the '
      'gateway search is shown', (WidgetTester tester) async {
    final _Proxy proxy = await _pumpShell(tester);

    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(_tab(tester), 1, reason: 'the test should start on Servers');

    await tester.tap(find.byType(NovaConnectButton));
    // Discrete pumps, not pumpAndSettle: 'connecting' spins the connect button
    // forever by design, so settling would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(proxy.calls, contains('connect'));
    expect(_tab(tester), 0, reason: 'Connect should land the user on Home');

    // Stop the spinner so the ticker is not still running at teardown.
    await proxy.disconnect();
    await tester.pump();
  });

  testWidgets('disconnecting leaves the user where they were',
      (WidgetTester tester) async {
    final _Proxy proxy =
        await _pumpShell(tester, initial: ProxyConnectionState.connected);

    await tester.tap(find.text('Servers'));
    await tester.pumpAndSettle();
    expect(_tab(tester), 1);

    await tester.tap(find.byType(NovaConnectButton));
    await tester.pumpAndSettle();

    expect(proxy.calls, contains('disconnect'));
    expect(_tab(tester), 1,
        reason: 'there is nothing to watch on Home when disconnecting, and '
            'moving the user off the list they were reading is its own annoyance');
  });
}
