import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import 'aether_gateway_search.dart';

/// The wait, promised before it starts.
///
/// A gateway search took about three minutes on the tester's network. Three
/// minutes of a silent button reads as a feature that is broken, so the two
/// places that can start one both say so up front, in the same words, out of
/// the same widget.
class AetherWaitHint extends StatelessWidget {
  const AetherWaitHint({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(NovaSpace.sm),
      decoration: BoxDecoration(
        color: nova.warning.withValues(alpha: 0.10),
        borderRadius: NovaRadii.smR,
        border: Border.all(color: nova.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            // The tint carries the warning and the icon carries the colour.
            // Amber on the light surface is about 2:1 against body text, so the
            // words themselves stay on a readable colour.
            child: Icon(Icons.schedule_rounded, size: 16, color: nova.warning),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(
              NovaStrings.of(context).aetherSlowHint,
              style: text.bodySmall?.copyWith(color: nova.muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where a running search has got to: which address it is on, how long it has
/// been going, and how many have already been ruled out.
///
/// This used to lead with three pixels of indeterminate bar. A tester watched
/// it for two minutes, read the screen as frozen, and gave up on a search that
/// had not finished rather than one that had failed. What replaced it is two
/// things that cannot be mistaken for a stall: a sweep that turns beside the
/// phase the search is in, and a clock that counts up.
///
/// Neither claims to know how far along the search is, because nothing here
/// does. The finder stops when an address carries traffic, not at a fraction,
/// so a bar filling towards an end would be a number invented to look
/// reassuring. The attempt count, the ruled-out count and the clock are all
/// measured.
class AetherProgressLines extends StatefulWidget {
  const AetherProgressLines({super.key, required this.progress});

  final AetherSearchProgress progress;

  @override
  State<AetherProgressLines> createState() => _AetherProgressLinesState();
}

class _AetherProgressLinesState extends State<AetherProgressLines> {
  /// Added up from the ticks rather than read off a wall clock: a [Stopwatch]
  /// does not follow the fake time a widget test runs on, and a second of drift
  /// across a three-minute wait is not a figure anyone reads to that precision.
  Duration _elapsed = Duration.zero;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // This widget is built when a search starts and removed when it ends, so
    // its own life is exactly the thing being timed.
    _tick = Timer.periodic(const Duration(seconds: 1),
        (_) => setState(() => _elapsed += const Duration(seconds: 1)));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// mm:ss. Past an hour the minutes keep counting rather than rolling into an
  /// hours field, because a search that long has gone wrong and hiding that in
  /// a 00 is the opposite of what this line is for.
  static String _clock(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:'
      '${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final AetherSearchProgress p = widget.progress;
    final String clock = _clock(_elapsed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _progressRow(context, s, nova, text, p, clock),
        // Below the row, not inside it: the switch to the fallback is a change
        // of plan, and a fourth muted line tucked under the attempt count was
        // read as more of the same spinner.
        if (p.usingFallback) ...<Widget>[
          const SizedBox(height: NovaSpace.sm),
          const AetherFallbackNote(),
        ],
      ],
    );
  }

  Widget _progressRow(BuildContext context, NovaStrings s, NovaColors nova,
      TextTheme text, AetherSearchProgress p, String clock) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PhaseSweep(verifying: p.verifying),
        const SizedBox(width: NovaSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                // The phase changes every half minute or so, and a reader who
                // cannot see the sweep has nothing else saying the wait is
                // still going anywhere.
                liveRegion: true,
                child: Text(
                  p.verifying
                      ? s.aetherVerifyingAt(p.attempt)
                      : s.aetherScanningAt(p.attempt),
                  style: text.bodySmall?.copyWith(color: nova.text),
                ),
              ),
              if (p.ruledOut > 0)
                Text(s.aetherRuledOut(p.ruledOut),
                    style: text.bodySmall?.copyWith(color: nova.muted)),
            ],
          ),
        ),
        const SizedBox(width: NovaSpace.sm),
        // The only figure here that moves every second, which is what turns an
        // open-ended wait into one with a length. Tabular so the digits sit
        // still instead of nudging the row as they change.
        Semantics(
          label: s.aetherElapsed(clock),
          excludeSemantics: true,
          child: Text(
            clock,
            style: text.bodySmall?.copyWith(
              color: nova.muted,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// The moment the search changes plan, said out loud.
///
/// After 90 seconds a MASQUE search is cancelled and started again over HTTP/2
/// with a split TLS hello. That used to show up as one more grey line under the
/// attempt count, which is indistinguishable from the spinner that was already
/// there, and it takes the address number back to one, which on its own reads
/// as the count losing its place. Both facts go here, tinted and iconed so the
/// change is visible before it is read, and announced for anyone listening to
/// the card instead of watching it.
///
/// Cyan rather than a warning colour: nothing has gone wrong, this is the
/// second half of the same search.
class AetherFallbackNote extends StatelessWidget {
  const AetherFallbackNote({super.key});

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final NovaColors nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(NovaSpace.sm),
        decoration: BoxDecoration(
          color: nova.cyan.withValues(alpha: 0.10),
          borderRadius: NovaRadii.smR,
          border: Border.all(color: nova.cyan.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.alt_route_rounded, size: 16, color: nova.cyan),
            ),
            const SizedBox(width: NovaSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    s.aetherH2Fallback,
                    style: text.bodySmall
                        ?.copyWith(color: nova.text, height: 1.35),
                  ),
                  Text(
                    s.aetherH2FallbackRestart,
                    style: text.bodySmall
                        ?.copyWith(color: nova.muted, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slow sweep around the glyph for the phase the search is in.
///
/// 2.4 seconds a turn, the tempo the free list search already uses: a fast
/// spinner beside a number that changes every half minute looks impatient, and
/// this screen is asking minutes of someone who is usually already anxious
/// about being cut off.
///
/// The glyph swaps when the search moves from looking for an address to proving
/// one, so that step is something to see and not only something to read. They
/// are the icons the buttons on the editor use for the same two jobs.
class _PhaseSweep extends StatefulWidget {
  const _PhaseSweep({required this.verifying});

  final bool verifying;

  @override
  State<_PhaseSweep> createState() => _PhaseSweepState();
}

class _PhaseSweepState extends State<_PhaseSweep>
    with SingleTickerProviderStateMixin {
  static const double _size = 24;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NovaColors nova = context.nova;
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          RotationTransition(
            turns: _c,
            child: CustomPaint(
              size: const Size.square(_size),
              painter:
                  _SweepPainter(nova.cyan, nova.cyan.withValues(alpha: 0.16)),
            ),
          ),
          AnimatedSwitcher(
            // Long enough to read as a change of state, short enough that it is
            // over before the eye goes looking for what moved.
            duration: const Duration(milliseconds: 180),
            child: Icon(
              widget.verifying ? Icons.verified_outlined : Icons.radar_rounded,
              key: ValueKey<bool>(widget.verifying),
              size: 13,
              color: nova.cyan,
            ),
          ),
        ],
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  const _SweepPainter(this.color, this.track);

  /// How much of the ring the moving head covers, in radians. Under half a
  /// turn, so there is always more gap than arc and the rotation has something
  /// to be read against.
  static const double _arc = 2.6;

  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = track;
    canvas.drawCircle(rect.center, size.width / 2 - 1, base);
    // One arc rather than a full ring: the gap is what makes the turn readable.
    // The gradient ends where the arc does, so the head reaches full colour
    // instead of stopping at the fraction of a whole turn the arc happens to
    // cover, which at this size left nothing anyone could see moving.
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        endAngle: _arc,
        colors: <Color>[color.withValues(alpha: 0), color],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(1), 0, _arc, false, arc);
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.color != color || old.track != track;
}
