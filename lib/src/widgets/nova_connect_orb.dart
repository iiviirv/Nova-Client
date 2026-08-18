import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/proxy/proxy_controller.dart';
import '../theme/nova_gradients.dart';
import '../theme/nova_semantics.dart';
import '../theme/nova_theme.dart';
import 'nova_logo.dart';

/// The signature connect control: a glowing ring around the Nova mark, colored
/// by the live connection state (cyan to violet idle, green connected, amber
/// busy).
///
/// Motion is deliberately cheap. Nothing ticks while the orb is idle or
/// connected: the ring only rotates and breathes while a connection is being
/// brought up or torn down, and a state change fades the ring's colours over
/// once (about a third of a second) rather than snapping. The paint is isolated
/// in its own [RepaintBoundary] so a redraw of the ring never touches the rest
/// of the dashboard, and the press feedback is a one-shot scale.
///
/// A port of the native `NovaConnectOrb`. In [showLabel] mode it stacks a top
/// status line + logo + bottom label; otherwise it is a clean logo-only orb
/// (the home hero uses this).
class NovaConnectOrb extends StatefulWidget {
  const NovaConnectOrb({
    super.key,
    required this.state,
    this.onTap,
    this.size = 232,
    this.showLabel = false,
    this.label,
    this.statusText,
  });

  final ProxyConnectionState state;
  final VoidCallback? onTap;
  final double size;
  final bool showLabel;
  final String? label;
  final String? statusText;

  @override
  State<NovaConnectOrb> createState() => _NovaConnectOrbState();
}

class _NovaConnectOrbState extends State<NovaConnectOrb>
    with TickerProviderStateMixin {
  /// Drives both the sweep rotation and the breathing glow while busy. Stopped
  /// (and therefore free) in every other state.
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  /// One-shot colour crossfade between the previous and current state.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: 1,
  );
  late final Animation<double> _fadeCurve =
      CurvedAnimation(parent: _fade, curve: Curves.easeOutCubic);

  ProxyConnectionState? _previous;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _syncMotion();
  }

  @override
  void didUpdateWidget(NovaConnectOrb old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      _previous = old.state;
      _syncMotion();
      _fade.forward(from: 0);
    }
  }

  void _syncMotion() {
    if (widget.state.isBusy) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion.stop();
      _motion.value = 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    _fade.dispose();
    super.dispose();
  }

  void _setPressed(bool v) {
    if (_pressed != v && widget.onTap != null) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final NovaConnectVisual to = NovaConnectVisual.of(widget.state, nova);
    final NovaConnectVisual from =
        NovaConnectVisual.of(_previous ?? widget.state, nova);
    final bool connected = widget.state.isActive;
    final bool wasConnected = (_previous ?? widget.state).isActive;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.statusText ?? widget.label,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[_motion, _fadeCurve]),
                builder: (context, child) {
                  final double t = reduceMotion ? 1 : _fadeCurve.value;
                  final double m = _motion.value;
                  return CustomPaint(
                    painter: _OrbPainter(
                      accent: Color.lerp(from.accent, to.accent, t)!,
                      sweep: _lerpSweep(
                        wasConnected
                            ? NovaGradients.orbSweepConnected
                            : NovaGradients.orbSweepIdle,
                        connected
                            ? NovaGradients.orbSweepConnected
                            : NovaGradients.orbSweepIdle,
                        t,
                      ),
                      connected: connected,
                      busy: widget.state.isBusy,
                      spin: m,
                      // Two breaths per rotation, derived from the same clock.
                      pulse: 0.5 - 0.5 * math.cos(m * 4 * math.pi),
                    ),
                    child: child,
                  );
                },
                child: Center(
                  child: widget.showLabel
                      ? _LabeledContent(
                          state: widget.state,
                          accent: to.accent,
                          size: widget.size,
                          label: widget.label,
                          statusText: widget.statusText,
                        )
                      : NovaLogo(size: widget.size * 0.56),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static List<Color> _lerpSweep(List<Color> a, List<Color> b, double t) {
    if (t >= 1 || identical(a, b)) return b;
    return List<Color>.generate(b.length, (i) => Color.lerp(a[i], b[i], t)!);
  }
}

class _LabeledContent extends StatelessWidget {
  const _LabeledContent({
    required this.state,
    required this.accent,
    required this.size,
    this.label,
    this.statusText,
  });

  final ProxyConnectionState state;
  final Color accent;
  final double size;
  final String? label;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (statusText != null)
          Text(statusText!,
              style: text.labelSmall?.copyWith(color: accent)),
        SizedBox(height: size * 0.04),
        NovaLogo(size: size * 0.30),
        SizedBox(height: size * 0.04),
        if (label != null)
          Text(label!,
              style: text.titleSmall
                  ?.copyWith(color: accent, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.accent,
    required this.sweep,
    required this.connected,
    required this.busy,
    required this.spin,
    required this.pulse,
  });

  final Color accent;
  final List<Color> sweep;
  final bool connected;
  final bool busy;
  final double spin; // 0..1 continuous while busy
  final double pulse; // 0..1 breathing while busy

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;

    final double strokeW = size.shortestSide * 0.05;
    // The sweep ring sits near the outer edge so the dark disc it encloses is
    // large enough to hold the Nova mark without the logo spilling past it.
    final double ringR = r - strokeW * 0.8;

    // 1) Radial glow, sized to the ring. Kept deliberately restrained (an
    // enterprise look, not a gamer neon): a soft presence, not a spotlight.
    final double glowAlpha = busy
        ? 0.14 + 0.10 * pulse
        : connected
            ? 0.22
            : 0.10;
    final Paint glow = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          accent.withValues(alpha: glowAlpha),
          accent.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: ringR));
    canvas.drawCircle(c, ringR, glow);

    // 2) Sweep ring stroke. Idle uses the cyan to violet sweep (matching the
    // native orb), not a flat single-accent ring.
    final double rot = busy ? spin * 2 * math.pi : -math.pi / 2;
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: sweep,
        transform: GradientRotation(rot),
      ).createShader(Rect.fromCircle(center: c, radius: ringR));
    canvas.drawCircle(c, ringR, ring);

    // 3) Inner dark screen disc filling the ring.
    final Paint disc = Paint()..color = const Color(0xFF0A0C12);
    canvas.drawCircle(c, ringR - strokeW * 0.6, disc);
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.accent != accent ||
      old.connected != connected ||
      old.busy != busy ||
      old.spin != spin ||
      old.pulse != pulse ||
      !identical(old.sweep, sweep);
}
