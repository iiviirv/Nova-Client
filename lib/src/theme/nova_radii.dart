import 'package:flutter/widgets.dart';

/// Layout tokens — radii, spacing scale, content width and elevation — from the
/// Nova design system.
class NovaRadii {
  const NovaRadii._();

  /// `--radius: 16px` — default card radius.
  static const double card = 16;

  /// `--radius-sm: 10px` — inputs, small chips, notes.
  static const double sm = 10;

  /// `--radius-pill: 999px`.
  static const double pill = 999;

  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius smR = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius pillR = BorderRadius.all(Radius.circular(pill));
}

/// 4-pt spacing scale used throughout the app shell.
class NovaSpace {
  const NovaSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// `--maxw: 1140px` — max readable content width on wide windows.
  static const double maxContentWidth = 1140;
}

/// Elevation tokens.
class NovaElevation {
  const NovaElevation._();

  /// `--shadow-accent: 0 10px 30px -10px rgba(99,102,241,0.7)` — primary buttons.
  static List<BoxShadow> accent(Color indigoStrong) => <BoxShadow>[
        BoxShadow(
          color: indigoStrong.withValues(alpha: 0.7),
          offset: const Offset(0, 10),
          blurRadius: 30,
          spreadRadius: -10,
        ),
      ];

  /// `--shadow-pop: 0 14px 30px rgba(0,0,0,0.35)` — menus / popovers.
  static const List<BoxShadow> pop = <BoxShadow>[
    BoxShadow(
      color: Color(0x59000000),
      offset: Offset(0, 14),
      blurRadius: 30,
    ),
  ];
}
