import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
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

void main() {
  for (final action in ['free', 'add']) {
  testWidgets('first run routes $action to its server tab',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final theme = ThemeController()..attachPrefs(prefs);
    final profiles = ProfilesController()..attachPrefs(prefs);
    final radar = RadarController()..attachPrefs(prefs);

    final proxy = MockProxyController();
    final relay = RelayController();
    final tunnel = TunnelController(relay.transportFor);
    await tester.pumpWidget(NovaApp(
      theme: theme,
      proxy: proxy,
      connInfo: ConnInfoController(proxy),
      profiles: profiles,
      radar: radar,
      settings: SettingsController(prefs: prefs),
      appRouting: AppRouting(),
      vps: VpsController(profiles, proxy, relay),
      relay: relay,
      tunnel: tunnel,
    ));
    // Advance past the minimum-splash hold before onboarding is reached.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Nova'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);

    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your connection'), findsOneWidget);
    expect(find.text('Free VPN servers'), findsOneWidget);
    expect(find.text('Aether'), findsOneWidget);
    expect(find.text('MasterDNS'), findsNothing);
    await tester.ensureVisible(find.text('Choose how to start'));
    await tester.tap(find.text('Choose how to start'));
    await tester.pumpAndSettle();
    expect(find.text('How would you like to start?'), findsOneWidget);
    expect(find.text('Set up Aether'), findsNothing);
    expect(find.text('Use MasterDNS'), findsNothing);
    expect(find.text('Use the free servers'), findsOneWidget);
    expect(find.text('Add a config'), findsOneWidget);
    // The panel-owner entries were removed from first run on purpose; they
    // live in Settings > Cloudflare tools and the Servers empty state.
    expect(find.text('Deploy your own panel'), findsNothing);
    expect(find.text('Import from your panel'), findsNothing);
    expect(find.text('Connect your VPS'), findsNothing);
    await tester.ensureVisible(find.text(action == 'free' ? 'Use the free servers' : 'Add a config'));
    await tester.tap(find.text(action == 'free' ? 'Use the free servers' : 'Add a config'));
    await tester.pumpAndSettle();
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('Subscriptions'), findsOneWidget);
    expect(profiles.freeTab, action == 'free');
    await tester.pumpWidget(const SizedBox.shrink());
    proxy.dispose();
  });
}
}
