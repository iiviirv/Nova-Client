import 'package:flutter/material.dart';

import '../theme/nova_gradients.dart';

/// The Nova "N" mark, drawn from the exact brand SVG path
/// (`brand/nova-logo-gradient.svg`, viewBox 0 0 100 100) so it stays pixel-true
/// to the marketing site without bundling an SVG renderer.
///
/// ```svg
/// M 28 22 L 28 64 A 13 13 0 0 0 54 64 L 54 36 A 13 13 0 0 1 80 36 L 80 78
/// stroke-width 15, round caps/joins, gradient #22d3ee → #a855f7
/// ```
class NovaLogo extends StatelessWidget {
  const NovaLogo({
    super.key,
    this.size = 40,
    this.gradient,
    this.color,
  });

  final double size;

  /// Overrides the brand gradient (e.g. for monochrome contexts).
  final Gradient? gradient;

  /// Solid color override (used by [NovaLogo.mono]). Wins over [gradient].
  final Color? color;

  /// A single-color mark — matches `nova-logo-white.svg` / `nova-logo-black.svg`.
  const NovaLogo.mono({super.key, this.size = 40, required Color this.color})
      : gradient = null;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NovaMarkPainter(
          gradient: color == null ? (gradient ?? NovaGradients.logo) : null,
          color: color,
        ),
      ),
    );
  }
}

/// The mark on a rounded gradient/dark badge — mirrors `nova-logo-tile.svg`
/// and the round badge used in the site nav and social cards.
class NovaLogoBadge extends StatelessWidget {
  const NovaLogoBadge({super.key, this.size = 56, this.tileColor});

  final double size;
  final Color? tileColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tileColor ?? const Color(0xFF05060A),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      alignment: Alignment.center,
      child: NovaLogo(size: size * 0.62),
    );
  }
}

class _NovaMarkPainter extends CustomPainter {
  _NovaMarkPainter({this.gradient, this.color})
      : assert(gradient != null || color != null);

  final Gradient? gradient;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    // Path authored in a 100×100 box; scale uniformly to the widget.
    final double s = size.shortestSide / 100.0;
    canvas.save();
    canvas.scale(s, s);

    final Path path = Path()
      ..moveTo(28, 22)
      ..lineTo(28, 64)
      ..arcToPoint(const Offset(54, 64),
          radius: const Radius.circular(13), clockwise: false)
      ..lineTo(54, 36)
      ..arcToPoint(const Offset(80, 36),
          radius: const Radius.circular(13), clockwise: true)
      ..lineTo(80, 78);

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (color != null) {
      paint.color = color!;
    } else {
      paint.shader =
          gradient!.createShader(const Rect.fromLTWH(0, 0, 100, 100));
    }

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NovaMarkPainter old) =>
      old.gradient != gradient || old.color != color;
}
