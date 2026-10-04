import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/ech_editor_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_button.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ECH lookup editor.
///
/// What these guard is the stored value and the readout. The field takes free
/// text whose unusable halves fall back silently, so a typo would otherwise
/// only show up later as a connection that quietly stopped using ECH, and a
/// value stored raw rather than as Nova read it would disagree with what the
/// screen just said.

late ProfilesController profiles;

ProxyProfile _profile({String? lookup}) => ProxyProfile(
      id: 'sub-1',
      name: 'Subscription',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.invalid/sub',
      echSni: true,
      echConfigList: lookup,
      updatedAt: DateTime(2026),
    );

/// Pumps a home screen whose one button opens the editor, so Save's pop has
/// somewhere to go.
Future<void> _pump(
  WidgetTester tester, {
  required ProxyProfile existing,
  Locale locale = const Locale('en'),
  // Tall enough that the whole editor is built at once: a ListView does not
  // build what is off screen.
  Size size = const Size(420, 3000),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final ThemeController theme = ThemeController()..attachPrefs(prefs);
  profiles = ProfilesController()
    ..attachPrefs(prefs)
    ..selectTab(false);
  profiles.add(existing);
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
      locale: locale,
      supportedLocales: ThemeController.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        NovaStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: NovaTheme.light(locale),
      darkTheme: NovaTheme.dark(locale),
      themeMode: ThemeMode.dark,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push<void>(
                  MaterialPageRoute<void>(
                      builder: (_) =>
                          EchEditorScreen(profileId: existing.id))),
              child: const Text('open'),
            ),
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

ProxyProfile get _saved =>
    profiles.profiles.firstWhere((ProxyProfile p) => p.id == 'sub-1');

Future<void> _type(WidgetTester tester, String value) async {
  await tester.enterText(find.byType(TextField), value);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(NovaButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an unedited profile offers the default and stores nothing',
      (WidgetTester tester) async {
    await _pump(tester, existing: _profile());

    // The field is empty with the default as its hint, so "using the default"
    // is visible rather than inferred.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text(EchSpec.fallback.text), findsOneWidget);
    // And the readout already says what that default resolves to.
    expect(find.text(EchSpec.fallback.domain), findsOneWidget);
    expect(find.text(EchSpec.fallback.resolver), findsOneWidget);

    await _save(tester);
    expect(_saved.echConfigList, isNull,
        reason: 'storing the default freezes it, so a later change to the '
            'default would never reach this profile');
  });

  testWidgets('the form other clients use is stored as typed',
      (WidgetTester tester) async {
    await _pump(tester, existing: _profile());
    await _type(tester, 'cloudflare-ech.com+udp://1.0.0.1');

    // The readout is the confirmation that the typo check is possible at all.
    expect(find.text('cloudflare-ech.com'), findsOneWidget);
    expect(find.text('udp://1.0.0.1'), findsOneWidget);

    await _save(tester);
    expect(_saved.echConfigList, 'cloudflare-ech.com+udp://1.0.0.1');
  });

  testWidgets('a half that Nova cannot use shows as the fallback it becomes',
      (WidgetTester tester) async {
    await _pump(tester, existing: _profile());
    await _type(tester, 'not a domain+udp://1.0.0.1');

    // The domain was dropped, and the readout says so before Save rather than
    // leaving it to be discovered as a connection without ECH.
    expect(find.text(EchSpec.fallback.domain), findsOneWidget);
    expect(find.text('udp://1.0.0.1'), findsOneWidget);

    await _save(tester);
    expect(_saved.echConfigList, '${EchSpec.fallback.domain}+udp://1.0.0.1',
        reason: 'what is stored is what the screen said, not the raw text');
  });

  testWidgets('clearing an override goes back to the default',
      (WidgetTester tester) async {
    await _pump(
        tester, existing: _profile(lookup: 'example.com+udp://9.9.9.9'));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'example.com+udp://9.9.9.9');

    await _type(tester, '   ');
    await _save(tester);
    expect(_saved.echConfigList, isNull);
  });

  testWidgets('typing the default back out stores nothing',
      (WidgetTester tester) async {
    await _pump(
        tester, existing: _profile(lookup: 'example.com+udp://9.9.9.9'));
    await _type(tester, EchSpec.fallback.text);
    await _save(tester);
    expect(_saved.echConfigList, isNull);
  });

  // A layout overflow throws in a widget test, so pumping the whole screen at
  // the narrowest phone and the largest text is the check that it fits. Both
  // languages, because Farsi is longer and runs the other way.
  for (final String language in <String>['en', 'fa']) {
    testWidgets('lays out at 320dp and 2x text in $language',
        (WidgetTester tester) async {
      await _pump(tester,
          existing: _profile(lookup: 'cloudflare-ech.com+udp://1.0.0.1'),
          locale: Locale(language),
          size: const Size(320, 4000),
          textScale: 2.0);

      expect(tester.takeException(), isNull);
      expect(find.byType(EchEditorScreen), findsOneWidget);

      // takeException catches a row that overflowed, and nothing else. The
      // quieter break is a line that fit by being cut, so every line in the
      // body is checked for both: inside the viewport, and not truncated.
      // Scoped to the list, because the app bar title is allowed to ellipsize.
      final Finder lines = find.descendant(
          of: find.byType(ListView), matching: find.byType(Text));
      expect(lines, findsWidgets);
      for (final Element e in lines.evaluate()) {
        final String? what = (e.widget as Text).data;
        final Rect r = tester.getRect(find.byWidget(e.widget));
        expect(r.left, greaterThanOrEqualTo(-0.01), reason: '$what');
        expect(r.right, lessThanOrEqualTo(320.01), reason: '$what');
        final RenderObject? ro = e.renderObject;
        if (ro is RenderParagraph) {
          expect(ro.didExceedMaxLines, isFalse,
              reason: 'cut short instead of wrapping: $what');
        }
      }
    });
  }

  testWidgets('the Farsi copy isolates its Latin names',
      (WidgetTester tester) async {
    await _pump(tester, existing: _profile(), locale: const Locale('fa'));

    // Farsi runs right to left, and a bare "ECH" inside it drags the
    // punctuation around it to the wrong end. Every Latin run is wrapped in
    // LRI/PDI, so the count of isolate marks is even and non-zero.
    final NovaStrings fa = NovaStrings(const Locale('fa'));
    for (final String line in <String>[
      fa.echEdit,
      fa.echEditTitle,
      fa.echEditIntro,
    ]) {
      final int open = '\u2066'.allMatches(line).length;
      final int close = '\u2069'.allMatches(line).length;
      expect(open, greaterThan(0), reason: line);
      expect(close, open, reason: line);
    }
  });
}
