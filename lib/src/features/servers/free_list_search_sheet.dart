import 'package:flutter/material.dart';

import '../../core/proxy/proxy_controller.dart';
import '../../l10n/nova_strings.dart';
import '../../widgets/nova_logo.dart';

/// The blocking "finding servers" screen, shown the first time Nova's free
/// list is opened on a device (and after a manual refresh).
///
/// The free list is other people's servers and a good fraction of them are
/// always gone, so the list is only worth showing once it has been swept. That
/// sweep takes the better part of a minute, and doing it quietly behind a
/// half-populated list meant rows appeared, reordered and vanished under the
/// user's finger while they were trying to pick one.
///
/// So it is shown instead of hidden: what is happening, how many working
/// servers have been found so far, and a way out. Stopping keeps everything
/// found up to that point, because a partial list of servers that answer is
/// more useful than no list.
///
/// It cannot be dismissed by accident (no barrier tap, no back gesture): the
/// only exits are finishing and the stop button, and both leave the list in a
/// state the user can act on.
class FreeListSearchSheet extends StatelessWidget {
  const FreeListSearchSheet({
    super.key,
    required this.proxy,
    required this.total,
    required this.onStop,
  });

  final ProxyController proxy;

  /// How many servers this sweep will try, for the "of N" in the count.
  final int total;

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const _SearchingMark(),
                    const SizedBox(height: 36),
                    Text(
                      s.freeSearchTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.freeSearchBody,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // The live count. This is the whole reason the screen
                    // exists: a spinner says "wait", a rising number says the
                    // waiting is producing something.
                    ValueListenableBuilder<CoreNodeHealth>(
                      valueListenable: proxy.coreHealth,
                      builder: (BuildContext context, CoreNodeHealth h, _) {
                        final int found = h.workingCount;
                        final int done = h.testedCount;
                        return Column(
                          children: <Widget>[
                            Text(
                              '$found',
                              style: theme.textTheme.displayMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.primary,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.freeSearchFound,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 20),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(99),
                              child: LinearProgressIndicator(
                                minHeight: 6,
                                value: total <= 0 ? null : done / total,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              s.freeSearchProgress
                                  .replaceFirst('{n}', '$done')
                                  .replaceFirst('{total}', '$total'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 36),
                    TextButton(
                      onPressed: onStop,
                      child: Text(s.freeSearchStop),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      s.freeSearchStopHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mark with a sweeping ring around it, so the screen reads as working
/// rather than stuck. Deliberately slow (2.4s a turn): a fast spinner next to a
/// number that changes every few seconds looks impatient.
class _SearchingMark extends StatefulWidget {
  const _SearchingMark();

  @override
  State<_SearchingMark> createState() => _SearchingMarkState();
}

class _SearchingMarkState extends State<_SearchingMark>
    with SingleTickerProviderStateMixin {
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
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          RotationTransition(
            turns: _c,
            child: CustomPaint(
              size: const Size(132, 132),
              painter: _RingPainter(
                theme.colorScheme.primary,
                theme.colorScheme.primary.withValues(alpha: 0.08),
              ),
            ),
          ),
          const NovaLogo(size: 76),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.color, this.track);

  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = track;
    canvas.drawCircle(rect.center, size.width / 2 - 2, base);
    // A single sweeping arc rather than a full ring: the gap is what makes the
    // rotation readable.
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: <Color>[color.withValues(alpha: 0), color],
      ).createShader(rect);
    canvas.drawArc(rect.deflate(2), 0, 2.6, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.track != track;
}
