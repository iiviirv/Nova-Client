import 'package:flutter/material.dart';

import '../../core/proxy/proxy_controller.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import 'speed_test.dart';

/// Measures the real download/upload throughput of the current connection, so a
/// user can compare configs on their own line (the auto-selector only ranks
/// latency). Connect through a config, run it, note the numbers, switch config,
/// run again.
class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  bool _running = false;
  double _down = 0;
  double _up = 0;
  int _ping = 0;
  String _phase = '';
  SpeedResult? _result;

  bool _gaming = false;
  int _gamingDone = 0;
  GamingResult? _gamingResult;

  /// The gaming test. Long and strictly sequential, so it gets its own button
  /// rather than being folded into the speed test: someone checking whether a
  /// config is playable is asking a different question from someone checking
  /// how fast it is, and the answer takes a hundred probes to give.
  Future<void> _runGaming() async {
    setState(() {
      _gaming = true;
      _gamingResult = null;
      _gamingDone = 0;
    });
    try {
      final GamingResult r = await SpeedTest().measureGaming(
        onProgress: (int done, int total) {
          if (mounted) setState(() => _gamingDone = done);
        },
        cancelled: () => !mounted,
      );
      if (!mounted) return;
      setState(() => _gamingResult = r);
    } finally {
      if (mounted) setState(() => _gaming = false);
    }
  }

  Future<void> _run() async {
    final NovaStrings s = NovaStrings.of(context);
    setState(() {
      _running = true;
      _result = null;
      _down = 0;
      _up = 0;
      _ping = 0;
      _phase = s.speedPhasePing;
    });
    try {
      final SpeedResult r = await SpeedTest().run(
        onPhase: (String phase) {
          if (!mounted) return;
          setState(() => _phase = switch (phase) {
                'latency' => s.speedPhasePing,
                'loss' => s.speedPhaseLoss,
                'download' => s.speedPhaseDown,
                _ => s.speedPhaseUp,
              });
        },
        onDown: (double m) {
          if (mounted) setState(() => _down = m);
        },
        onUp: (double m) {
          if (mounted) setState(() => _up = m);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _down = r.downMbps;
        _up = r.upMbps;
        _ping = r.pingMs;
        _phase = '';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final ProxyController proxy = NovaScope.of(context).proxy;
    final bool connected = proxy.state.isActive;
    final SpeedResult? r = _result;

    return Scaffold(
      appBar: AppBar(title: Text(s.speedTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            children: <Widget>[
              // Connected-or-not banner: makes clear WHAT is being measured.
              Container(
                padding: const EdgeInsets.all(NovaSpace.md),
                decoration: BoxDecoration(
                  color: (connected ? nova.successStrong : nova.warning)
                      .withValues(alpha: 0.12),
                  borderRadius: NovaRadii.smR,
                  border: Border.all(
                      color: (connected ? nova.successStrong : nova.warning)
                          .withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                        connected
                            ? Icons.shield_rounded
                            : Icons.info_outline_rounded,
                        size: 18,
                        color: connected ? nova.successStrong : nova.warning),
                    const SizedBox(width: NovaSpace.sm),
                    Expanded(
                      child: Text(
                        connected ? s.speedThroughTunnel : s.speedDirect,
                        style:
                            text.bodySmall?.copyWith(color: nova.muted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: NovaSpace.lg),

              // Big live download readout.
              NovaCard(
                child: Column(
                  children: <Widget>[
                    Text(s.speedDownload,
                        style: text.labelMedium
                            ?.copyWith(color: nova.muted)),
                    const SizedBox(height: NovaSpace.sm),
                    Text(
                      _down.toStringAsFixed(_down >= 100 ? 0 : 1),
                      style: text.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700, color: nova.cyan),
                    ),
                    Text('Mbps',
                        style: text.bodySmall?.copyWith(color: nova.muted)),
                  ],
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MiniStat(
                      label: s.speedUpload,
                      value: _up.toStringAsFixed(_up >= 100 ? 0 : 1),
                      unit: 'Mbps',
                    ),
                  ),
                  const SizedBox(width: NovaSpace.md),
                  Expanded(
                    child: _MiniStat(
                      label: s.speedPing,
                      value: _ping == 0 ? '-' : '$_ping',
                      unit: 'ms',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.md),
              // The two numbers that decide whether a config is playable. A
              // steady 90ms beats a 40ms line that swings 60ms or drops 3%.
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MiniStat(
                      label: s.speedJitter,
                      value: r == null ? '-' : r.jitterMs.toStringAsFixed(1),
                      unit: 'ms',
                    ),
                  ),
                  const SizedBox(width: NovaSpace.md),
                  Expanded(
                    child: _MiniStat(
                      label: s.speedLoss,
                      value: r == null || r.probesSent == 0
                          ? '-'
                          : r.lossPercent.toStringAsFixed(2),
                      unit: '%',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.lg),

              NovaButton(
                label: _running
                    ? (_phase.isEmpty ? s.speedRunning : _phase)
                    : (_result == null ? s.speedRun : s.speedAgain),
                icon: Icons.speed_rounded,
                expand: true,
                loading: _running,
                onPressed: _running ? null : _run,
              ),
              const SizedBox(height: NovaSpace.md),
              NovaButton(
                label: _gaming
                    ? s.gamingRunning
                        .replaceFirst('{n}', '$_gamingDone')
                        .replaceFirst('{t}', '${SpeedTest.kGamingProbes}')
                    : (_gamingResult == null ? s.gamingRun : s.gamingAgain),
                icon: Icons.sports_esports_rounded,
                variant: NovaButtonVariant.secondary,
                expand: true,
                loading: _gaming,
                onPressed: (_gaming || _running) ? null : _runGaming,
              ),
              if (_gamingResult != null) ...<Widget>[
                const SizedBox(height: NovaSpace.md),
                _GamingCard(result: _gamingResult!),
              ],
              const SizedBox(height: NovaSpace.md),
              Text(
                s.speedNote,
                style: text.bodySmall?.copyWith(color: nova.muted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The gaming verdict: one score, then the numbers behind it, then how that
/// score was arrived at. The breakdown is shown rather than hidden because the
/// whole point of the weighting is that it is arguable.
class _GamingCard extends StatelessWidget {
  const _GamingCard({required this.result});

  final GamingResult result;

  Color _scoreColor(BuildContext context, int score) {
    final nova = context.nova;
    if (score >= 85) return NovaSemantics.successGreen;
    if (score >= 70) return nova.cyan;
    if (score >= 50) return NovaSemantics.amber;
    return NovaSemantics.red;
  }

  String _grade(NovaStrings s, int score) {
    if (score >= 85) return s.gamingGradeExcellent;
    if (score >= 70) return s.gamingGradeGood;
    if (score >= 50) return s.gamingGradeOk;
    if (score >= 30) return s.gamingGradePoor;
    return s.gamingGradeBad;
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final GamingResult r = result;
    final Color c = _scoreColor(context, r.score);
    String ms(double v) => v.toStringAsFixed(v >= 100 ? 0 : 1);

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${r.score}',
                    style: text.displaySmall
                        ?.copyWith(fontWeight: FontWeight.w700, color: c)),
              ),
              const SizedBox(width: NovaSpace.sm),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('/ 100',
                    style: text.bodySmall?.copyWith(color: nova.muted)),
              ),
              const Spacer(),
              _Pill(label: _grade(s, r.score), color: c),
            ],
          ),
          const SizedBox(height: NovaSpace.md),
          const Divider(height: 1),
          const SizedBox(height: NovaSpace.md),

          Text(s.gamingLatencySpread,
              style: text.labelSmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.xs),
          _Row2(a: s.gamingMin, av: '${ms(r.minMs)} ms',
                b: s.gamingMedian, bv: '${ms(r.medianMs)} ms'),
          _Row2(a: s.gamingAvg, av: '${ms(r.avgMs)} ms',
                b: s.gamingP95, bv: '${ms(r.p95Ms)} ms'),
          _Row2(a: s.gamingMax, av: '${ms(r.maxMs)} ms',
                b: s.speedJitter, bv: '${ms(r.jitterMs)} ms'),

          const SizedBox(height: NovaSpace.md),
          Text(s.gamingStability,
              style: text.labelSmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.xs),
          _Row2(
            a: s.speedLoss,
            av: '${r.lossPercent.toStringAsFixed(2)} %',
            b: s.gamingBurst,
            bv: '${r.maxConsecutiveLoss}',
          ),
          _Row2(
            a: s.gamingSpike,
            av: '${ms(r.spikeMs)} ms',
            b: s.gamingSamples,
            bv: '${r.received} / ${r.samples}',
          ),

          const SizedBox(height: NovaSpace.md),
          Text(s.gamingBreakdown,
              style: text.labelSmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.xs),
          _Bar(label: s.speedLoss, score: r.lossScore, weight: GamingWeights.loss),
          _Bar(label: s.speedJitter, score: r.jitterScore, weight: GamingWeights.jitter),
          _Bar(label: s.gamingSpike, score: r.spikeScore, weight: GamingWeights.spike),
          _Bar(label: s.speedPing, score: r.latencyScore, weight: GamingWeights.latency),

          const SizedBox(height: NovaSpace.sm),
          Text(s.gamingNote,
              style: text.bodySmall?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: NovaSpace.md, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: NovaRadii.iconChipR,
        ),
        child: Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color, fontWeight: FontWeight.w700)),
      );
}

/// Two label/value pairs on one line. Values are Latin runs, held LTR so they
/// are not mirrored when the app is in Farsi.
class _Row2 extends StatelessWidget {
  const _Row2({required this.a, required this.av, required this.b, required this.bv});
  final String a, av, b, bv;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final TextTheme t = Theme.of(context).textTheme;
    Widget cell(String label, String value) => Expanded(
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(label,
                    style: t.bodySmall?.copyWith(color: nova.muted),
                    overflow: TextOverflow.ellipsis),
              ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(value,
                    style: t.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          cell(a, av),
          const SizedBox(width: NovaSpace.lg),
          cell(b, bv),
        ],
      ),
    );
  }
}

/// One component of the score, with the weight it carried.
class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.score, required this.weight});
  final String label;
  final int score;
  final int weight;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final TextTheme t = Theme.of(context).textTheme;
    final Color c = score >= 85
        ? NovaSemantics.successGreen
        : score >= 70
            ? nova.cyan
            : score >= 50
                ? NovaSemantics.amber
                : NovaSemantics.red;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(label,
                style: t.bodySmall?.copyWith(color: nova.muted),
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: score / 100,
                minHeight: 6,
                backgroundColor: nova.border,
                valueColor: AlwaysStoppedAnimation<Color>(c),
              ),
            ),
          ),
          const SizedBox(width: NovaSpace.sm),
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 64,
              child: Text('$score  x$weight',
                  textAlign: TextAlign.end,
                  style: t.labelSmall?.copyWith(color: nova.muted)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, required this.unit});
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        children: <Widget>[
          Text(label, style: text.labelSmall?.copyWith(color: nova.muted)),
          const SizedBox(height: 4),
          Text(value,
              style:
                  text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text(unit, style: text.bodySmall?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }
}
