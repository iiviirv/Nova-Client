import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/app_routing.dart';
import 'package:nova_client/src/core/proxy/conn_info_controller.dart';
import 'package:nova_client/src/core/proxy/mock_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/radar/radar_controller.dart';
import 'package:nova_client/src/features/relay/relay_controller.dart';
import 'package:nova_client/src/features/relay/tunnel_controller.dart';
import 'package:nova_client/src/features/servers/psiphon_editor_screen.dart';
import 'package:nova_client/src/features/settings/settings_controller.dart';
import 'package:nova_client/src/features/vps/vps_controller.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';
import 'package:nova_client/src/theme/theme_controller.dart';
import 'package:nova_client/src/widgets/nova_button.dart';
import 'package:nova_client/src/widgets/nova_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Psiphon editor.
///
/// What these guard is the stored profile and the one thing the screen owes
/// the user. A Psiphon profile holds exactly one choice, so a screen that
/// stores the wrong one stores a connection that comes out in the wrong place
/// with nothing on the row to say so. And both modes are slow to connect, the
/// chained one slower, which has to be said before the wait rather than after.

late ProfilesController profiles;

/// Pumps a home screen whose one button opens the editor, so Save's pop has
/// somewhere to go.
Future<void> _pump(
  WidgetTester tester, {
  ProxyProfile? existing,
  List<ProxyProfile> seed = const <ProxyProfile>[],
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
                          PsiphonEditorScreen(existing: existing))),
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

List<ProxyProfile> get _saved => profiles.profiles
    .where((ProxyProfile p) => p.kind == ProxyKind.psiphon)
    .toList();

Future<void> _tapText(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(NovaButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a new profile starts direct and stores the mode that was chosen',
      (WidgetTester tester) async {
    await _pump(tester);

    // Direct is the default: it is the mode that works with nothing else
    // running.
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(
        tester
            .widget<Icon>(find.byIcon(Icons.radio_button_checked_rounded))
            .color,
        isNotNull);

    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Psiphon over WARP');
    await _tapText(tester, 'Through Aether');
    await _save(tester);

    expect(_saved, hasLength(1));
    final ProxyProfile p = _saved.single;
    expect(p.name, 'Psiphon over WARP');
    expect(p.kind, ProxyKind.psiphon);
    expect(PsiphonConfig.modeFromLink(p.uri), PsiphonMode.throughAether,
        reason: 'the mode is the whole profile; storing the other one is a '
            'connection that comes out in the wrong country');
  });

  testWidgets('saving with nothing typed stores direct under a default name',
      (WidgetTester tester) async {
    await _pump(tester);
    await _save(tester);

    expect(_saved, hasLength(1));
    expect(_saved.single.name, 'Psiphon');
    expect(PsiphonConfig.modeFromLink(_saved.single.uri), PsiphonMode.direct);
  });

  // The chained mode costs time, because two layers come up instead of one.
  // That belongs next to the choice, not in an error afterwards. What must
  // never appear is an instruction to connect something first: the app holds
  // one active profile at a time, so a person could not do it.
  testWidgets('Through Aether says what it costs, where it is chosen',
      (WidgetTester tester) async {
    await _pump(tester);

    expect(find.textContaining('Slower to start than direct'), findsOneWidget);
    expect(find.textContaining('tunnel comes up first'), findsOneWidget);
    for (final String impossible in <String>[
      'while an Aether tunnel is connected',
      'Build one first',
      'Connect an Aether',
    ]) {
      expect(find.textContaining(impossible), findsNothing,
          reason: 'one active profile at a time means this cannot be done');
    }

    // Inside the option, not further down the page: the row being tapped is
    // what the person is reading when they choose. Measured as containment
    // rather than as a gap, because a gap that happens to be small is not the
    // same claim.
    final Finder tile =
        find.ancestor(of: find.text('Through Aether'), matching: find.byType(InkWell))
            .first;
    final Rect row = tester.getRect(tile);
    final Rect need =
        tester.getRect(find.textContaining('Slower to start than direct'));
    expect(row.contains(need.topLeft), isTrue);
    expect(row.contains(need.bottomRight), isTrue);

    // And the Direct option does not repeat it.
    final Rect direct = tester.getRect(
        find.ancestor(of: find.text('Direct'), matching: find.byType(InkWell))
            .first);
    expect(direct.contains(need.center), isFalse);
  });

  testWidgets('the three-minute wait is promised before it is waited through',
      (WidgetTester tester) async {
    await _pump(tester);
    expect(find.textContaining('about three minutes'), findsOneWidget,
        reason: 'a silent three-minute connect reads as a hang, which is how '
            'a working protocol got reported as a bug once already');
  });

  testWidgets('editing a saved profile keeps its id and shows its mode',
      (WidgetTester tester) async {
    final ProxyProfile saved = ProxyProfile(
      id: 'psi-1',
      name: 'Chained',
      kind: ProxyKind.psiphon,
      uri: PsiphonConfig.linkFor(PsiphonMode.throughAether),
      updatedAt: DateTime(2026),
    );
    await _pump(tester, existing: saved, seed: <ProxyProfile>[saved]);

    expect(find.text('Edit Psiphon connection'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Name'))
            .controller!
            .text,
        'Chained');

    // The saved mode is the one on screen, so the radio next to Through Aether
    // is the filled one.
    final Offset chained = tester.getCenter(find.text('Through Aether'));
    final Offset mark =
        tester.getCenter(find.byIcon(Icons.radio_button_checked_rounded));
    expect((mark.dy - chained.dy).abs(), lessThan(60));

    await _tapText(tester, 'Direct');
    await _save(tester);

    expect(_saved, hasLength(1));
    expect(_saved.single.id, 'psi-1');
    expect(PsiphonConfig.modeFromLink(_saved.single.uri), PsiphonMode.direct);
  });

  // A layout overflow throws in a widget test, so pumping the whole screen at
  // the narrowest phone and the largest text is the check that it fits. Both
  // languages, because Farsi is longer and runs the other way.
  for (final String language in <String>['en', 'fa']) {
    testWidgets('lays out at 320dp and 2x text in $language',
        (WidgetTester tester) async {
      await _pump(tester,
          locale: Locale(language),
          size: const Size(320, 4000),
          textScale: 2.0);

      expect(tester.takeException(), isNull);
      expect(find.byType(PsiphonEditorScreen), findsOneWidget);

      // takeException catches a row that overflowed, and nothing else. The
      // quieter break is a line that fit by being cut, which is what happens
      // to Farsi at this size, so every line in the body is checked for both:
      // inside the viewport, and not truncated.
      //
      // Scoped to the list: the app bar title is allowed to ellipsize, and
      // does at this text scale.
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
      // The line about the slower start is the one that has to survive: it
      // sits inside a nested surface, and it is what stops the longer wait
      // reading as a hang.
      expect(
          find.textContaining(language == 'en'
              ? 'Slower to start than direct'
              : 'دیرتر از حالت مستقیم'),
          findsOneWidget);
    });

    testWidgets('the wait note survives 320dp and 2x text in $language',
        (WidgetTester tester) async {
      await _pump(tester,
          locale: Locale(language),
          size: const Size(320, 4000),
          textScale: 2.0);

      expect(tester.takeException(), isNull);
      expect(
          find.textContaining(language == 'en' ? 'three minutes' : 'سه دقیقه'),
          findsOneWidget);
    });
  }

  testWidgets('the Farsi copy isolates its Latin names',
      (WidgetTester tester) async {
    await _pump(tester, locale: const Locale('fa'));

    // Farsi runs right to left, and a bare "Psiphon" inside it drags the
    // punctuation around it to the wrong end. Every Latin run is wrapped in
    // LRI/PDI, so the count of isolate marks is even and non-zero.
    final NovaStrings fa = NovaStrings(const Locale('fa'));
    for (final String line in <String>[
      fa.psiphonIntro,
      fa.psiphonDirectSub,
      fa.psiphonAether,
      fa.psiphonAetherSub,
      fa.psiphonAetherSlower,
      fa.psiphonSlow,
    ]) {
      final int open = '\u2066'.allMatches(line).length;
      final int close = '\u2069'.allMatches(line).length;
      expect(open, greaterThan(0), reason: line);
      expect(close, open, reason: line);
    }
  });
}
