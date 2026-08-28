import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nova_client/src/app.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/theme/theme_controller.dart';

Future<void> _pumpShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController()..attachPrefs(prefs);
  await theme.setOnboarded(); // skip onboarding → land on the app shell
  final profiles = ProfilesController()..attachPrefs(prefs);
  final proxy = MockProxyController();
  final relay = RelayController();
  final tunnel = TunnelController(relay.transportFor);

  await tester.pumpWidget(NovaApp(
    theme: theme,
    proxy: proxy,
    connInfo: ConnInfoController(proxy),
    profiles: profiles,
    radar: RadarController()..attachPrefs(prefs),
    settings: SettingsController(prefs: prefs),
    appRouting: AppRouting(),
    vps: VpsController(profiles, proxy, relay),
    relay: relay,
    tunnel: tunnel,
  ));
  // Advance past the minimum-splash hold (started in a post-frame callback), so
  // the gate moves on to the shell.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1600));
  // The connect orb pulses continuously, so the tree never fully settles;
  // pump a couple of fixed frames instead of pumpAndSettle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('app boots and shows the navigation destinations',
      (tester) async {
    await _pumpShell(tester);

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Servers'), findsWidgets);
    expect(find.text('Stats'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('tapping the Servers destination shows the servers screen',
      (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.text('Servers').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The Servers screen exposes an Add action: now a small floating + button
    // over the list rather than a labelled header button.
    expect(find.byIcon(Icons.add_rounded), findsWidgets);
  });
}
