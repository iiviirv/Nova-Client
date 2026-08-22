import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/proxy/proxy_controller.dart';
import '../theme/nova_colors.dart';
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
/// (the home hero uses this) that can take [inlineDetail] readouts into its
/// face once there is something live to report.
class NovaConnectOrb extends StatefulWidget {
  const NovaConnectOrb({
    super.key,
    required this.state,
    this.onTap,
    this.size = 232,
    this.showLabel = false,
    this.label,
    this.statusText,
    this.inlineDetail,
  });

  final ProxyConnectionState state;
  final VoidCallback? onTap;

  /// The target diameter. A change is eased into over [_kMorph] rather than
  /// snapping, so a caller can hand the orb a smaller size once a connection is
  /// up and the ring settles into it.
  final double size;
  final bool showLabel;
  final String? label;
  final String? statusText;

  /// Readouts to carry inside the ring, under the mark (the home hero puts the
  /// uptime clock and the traffic verdict here once connected). Handing the orb
  /// a detail shrinks the mark to make room and fades the readouts in; taking it
  /// away reverses both. Sized to fit the disc at any text scale.
  final Widget? inlineDetail;

  @override
  State<NovaConnectOrb> createState() => _NovaConnectOrbState();
}

/// The screen the ring encloses. Near-black in both themes, like the face of an
/// instrument rather than a panel of the page.
const Color _kOrbDisc = Color(0xFF0A0C12);

/// Ink for anything printed on that disc. The current theme's foreground is
/// near-black in light mode, which would vanish here, so on-disc text takes the
/// dark palette's foreground in both themes.
final Color kNovaOrbInk = NovaColors.dark.text;

/// How long the orb takes to grow, shrink, or take on its inline readouts.
/// Short enough to read as part of the same tap that caused it, long enough to
/// be a move rather than a cut.
const Duration _kMorph = Duration(milliseconds: 240);

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

  /// Drives the mark shrinking and the inline readouts fading in, in both
  /// directions. Held at rest (0 or 1) the rest of the time.
  late final AnimationController _detail = AnimationController(
    vsync: this,
    duration: _kMorph,
    // Readouts leave a touch quicker than they arrive, and leave early rather
    // than late: on a disconnect the text should be gone before the ring has
    // finished growing back, not still sitting in a circle that has moved on.
    reverseDuration: const Duration(milliseconds: 180),
    value: widget.inlineDetail != null ? 1 : 0,
  );
  late final Animation<double> _detailCurve = CurvedAnimation(
    parent: _detail,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// The readouts stay in the tree while they fade back out, so a disconnect
  /// reverses the same move instead of cutting the text away mid-fade.
  Widget? _detailChild;

  ProxyConnectionState? _previous;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _detailChild = widget.inlineDetail;
    _detail.addStatusListener(_dropFadedOutDetail);
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
    if (widget.inlineDetail != null) {
      _detailChild = widget.inlineDetail;
      if (_detail.status != AnimationStatus.completed) _detail.forward();
    } else if (old.inlineDetail != null) {
      _detail.reverse();
    }
  }

  void _dropFadedOutDetail(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        widget.inlineDetail == null &&
        _detailChild != null) {
      setState(() => _detailChild = null);
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
    _detail.dispose();
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
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: widget.size),
            duration: reduceMotion ? Duration.zero : _kMorph,
            curve: Curves.easeOutCubic,
            builder: (context, double size, _) => SizedBox(
              width: size,
              height: size,
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
                            size: size,
                            label: widget.label,
                            statusText: widget.statusText,
                          )
                        : _OrbFace(
                            size: size,
                            progress: _detailCurve,
                            detail: _detailChild,
                          ),
                  ),
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

/// What sits inside the ring: the mark, and under it the optional readouts.
///
/// The mark shrinks and the readouts open out of the same eased value, so the
/// two read as one move rather than two animations that happen to overlap. The
/// whole face is measured against the disc it has to live in and scaled down if
/// a large text setting would push it past the edge, which is why the caller
/// hands over styled widgets and not strings.
class _OrbFace extends StatelessWidget {
  const _OrbFace({
    required this.size,
    required this.progress,
    this.detail,
  });

  final double size;
  final Animation<double> progress;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final Widget? detail = this.detail;
    if (detail == null) return NovaLogo(size: size * 0.56);

    // What the disc can hold. Wider than it is tall on purpose: the widest
    // readout (a clock) sits near the middle of the circle, where the chord is
    // at its widest, so a square would waste the room the numbers need.
    return SizedBox(
      width: size * 0.68,
      height: size * 0.60,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: AnimatedBuilder(
            animation: progress,
            builder: (BuildContext context, Widget? child) {
              final double t = progress.value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  NovaLogo(size: size * (0.56 - 0.28 * t)),
                  SizedBox(height: size * 0.035 * t),
                  Align(
                    alignment: Alignment.topCenter,
                    heightFactor: t,
                    child: Opacity(
                      opacity: t,
                      // Readouts arrive at very nearly full size: text that
                      // grows from nothing reads as a pop, not an arrival.
                      child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
                    ),
                  ),
                ],
              );
            },
            child: detail,
          ),
        ),
      ),
    );
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
    final Paint disc = Paint()..color = _kOrbDisc;
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
