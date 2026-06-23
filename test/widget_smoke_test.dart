import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/app.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/theme/theme_controller.dart';

void main() {
  testWidgets('app boots and shows the navigation destinations',
      (tester) async {
    await tester.pumpWidget(NovaApp(
      theme: ThemeController(),
      proxy: MockProxyController(),
      profiles: ProfilesController(),
      radar: RadarController(),
    ));
    await tester.pump();

    // The dashboard header brand wordmark is present.
    expect(find.text('Nova Client'), findsWidgets);
    // Navigation labels are present.
    expect(find.text('Radar'), findsWidgets);
  });

  testWidgets('tapping the Radar destination shows the scanner',
      (tester) async {
    await tester.pumpWidget(NovaApp(
      theme: ThemeController(),
      proxy: MockProxyController(),
      profiles: ProfilesController(),
      radar: RadarController(),
    ));
    await tester.pump();

    await tester.tap(find.text('Radar').first);
    await tester.pump();

    expect(find.text('Nova Radar'), findsWidgets);
  });
}
