import 'package:flutter/material.dart';

import 'nova_logo.dart';

/// The brief loading page shown before the theme and saved locale are read.
/// Because the locale is not known yet, the tagline is shown in both English
/// and Farsi at once, which also doubles as a small statement of what Nova is
/// for. Colours are pinned (not theme tokens) since the theme extension may not
/// be resolved this early; the app is dark from the first frame regardless.
class NovaSplash extends StatelessWidget {
  const NovaSplash({super.key});

  /// Exposed so a test can assert both taglines render without duplicating the
  /// strings. English first, Farsi second.
  static const String taglineEn = 'The open internet, for everyone';
  static const String taglineFa = 'اینترنت آزاد، برای همه';

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0B0D12),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              NovaLogo(size: 92),
              SizedBox(height: 22),
              Text(
                'Nova',
                style: TextStyle(
                  color: Color(0xFFF5F7FA),
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              SizedBox(height: 10),
              // English and Farsi taglines, stacked. Each is a single script, so
              // no bidi isolates are needed.
              Text(
                taglineEn,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xCCB6BECC),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
              SizedBox(height: 4),
              Text(
                taglineFa,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0x99B6BECC),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
