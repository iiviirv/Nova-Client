import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/widgets/nova_splash.dart';

/// The pre-load splash must carry both taglines (English and Farsi) so the
/// slogan is shown regardless of the not-yet-known locale, and the Farsi run
/// must render right-to-left.
void main() {
  testWidgets('splash shows the wordmark and both taglines', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NovaSplash()));

    expect(find.text('Nova'), findsOneWidget);
    expect(find.text(NovaSplash.taglineEn), findsOneWidget);
    expect(find.text(NovaSplash.taglineFa), findsOneWidget);
  });

  testWidgets('the Farsi tagline is laid out right-to-left', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NovaSplash()));

    final Text fa = tester.widget<Text>(find.text(NovaSplash.taglineFa));
    expect(fa.textDirection, TextDirection.rtl);
  });
}
