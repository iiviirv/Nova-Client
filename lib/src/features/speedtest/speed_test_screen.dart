import 'package:flutter/material.dart';

import '../../core/proxy/proxy_controller.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
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
