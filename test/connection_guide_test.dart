import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/onboarding/connection_guide.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';
import 'package:nova_client/src/theme/nova_theme.dart';

void main() {
  for (final bool fa in <bool>[false, true]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('guide remains readable at large text, fa=$fa dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = Locale(fa ? 'fa' : 'en');
        await tester.pumpWidget(MaterialApp(
          locale: locale,
          supportedLocales: const <Locale>[Locale('en'), Locale('fa')],
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            NovaStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: dark ? NovaTheme.dark(locale) : NovaTheme.light(locale),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const ConnectionGuideScreen(),
        ));
        await tester.pumpAndSettle();
        expect(
            find.text(fa ? 'روش اتصال را انتخاب کنید' : 'Choose your connection'),
            findsOneWidget);
        expect(
            Directionality.of(
                tester.element(find.byType(ConnectionGuideContent))),
            fa ? TextDirection.rtl : TextDirection.ltr);
        await tester.ensureVisible(find.text('MasterDNS'));
        await tester.pumpAndSettle();
        expect(find.text('MasterDNS').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
