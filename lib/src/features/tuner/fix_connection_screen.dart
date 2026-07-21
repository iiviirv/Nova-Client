import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import 'connection_fixer.dart';

/// "Find a working setup": a guided, honest flow that tests every anti-censorship
/// fingerprint on the user's real network, measures which ones actually get past
/// the DPI (and how fast), then applies the best. It reconnects several times and
/// takes a couple of minutes, so the UI says so up front and offers Cancel at
/// every step. The backend ([ConnectionFixer]) does the work; this only drives
/// and narrates it.
class FixConnectionScreen extends StatefulWidget {
  const FixConnectionScreen({super.key});

  @override
  State<FixConnectionScreen> createState() => _FixConnectionScreenState();
}

/// Which panel the screen is showing.
enum _Stage { idle, running, result }

/// Per-setup state in the running stepper.
enum _StepState { pending, active, reachable, blocked }

class _FixConnectionScreenState extends State<FixConnectionScreen> {
  _Stage _stage = _Stage.idle;

  ConnectionFixer? _fixer;
  FixProgress? _progress;
  FixOutcome? _outcome;

  // Each candidate's measured result as it lands, keyed by candidate index, so
  // the stepper can fill rows in live.
  final Map<int, FixResult> _results = <int, FixResult>{};

  // The final phase, where the fixer reconnects onto the winning setup.
  bool _applying = false;

  // The user pressed Cancel and we are waiting for the run to unwind.
  bool _cancelling = false;

  @override
  void dispose() {
    // If a run is still in flight when the screen goes away, stop it so the
    // tunnel is not left cycling in the background.
    if (_stage == _Stage.running) _fixer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final ConnectionFixer fixer = ConnectionFixer(
      NovaScope.of(context).proxy,
      NovaScope.of(context).settings,
    );
    setState(() {
      _fixer = fixer;
      _stage = _Stage.running;
      _progress = null;
      _outcome = null;
      _results.clear();
      _applying = false;
      _cancelling = false;
    });

    final FixOutcome outcome = await fixer.run(
      onProgress: (FixProgress p) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          final FixResult? r = p.result;
          if (p.phase == 'result' && r != null) _results[p.index] = r;
          if (p.phase == 'applying') _applying = true;
        });
      },
    );

    if (!mounted) return;
    // A cancel is a quiet dismiss: just step back out of the flow.
    if (outcome.cancelled) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _outcome = outcome;
      _stage = _Stage.result;
    });
  }

  void _cancel() {
    setState(() => _cancelling = true);
    _fixer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);

    // While a run is in flight, a back gesture would abandon it mid-reconnect;
    // intercept it and cancel cleanly instead of tearing the screen out.
    return PopScope(
      canPop: _stage != _Stage.running,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && _stage == _Stage.running && !_cancelling) _cancel();
      },
      child: _buildScaffold(context, s),
    );
  }

  Widget _buildScaffold(BuildContext context, NovaStrings s) {
    return Scaffold(
      appBar: AppBar(title: Text(s.fixTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: switch (_stage) {
            _Stage.idle => _IdlePanel(onStart: _start),
            _Stage.running => _RunningPanel(
                progress: _progress,
                results: _results,
                applying: _applying,
                cancelling: _cancelling,
                onCancel: _cancel,
              ),
            _Stage.result => _ResultPanel(
                outcome: _outcome!,
                onRetry: _start,
                onClose: () => Navigator.of(context).maybePop(),
              ),
          },
        ),
      ),
    );
  }
}

/// Latin brand labels for the fingerprints; only 'randomized' is localized.
String _fpLabel(String choice, NovaStrings s) {
  if (choice == 'randomized') return s.fixFpRandomized;
  const Map<String, String> brand = <String, String>{
    'chrome': 'Chrome',
    'firefox': 'Firefox',
    'safari': 'Safari',
    'edge': 'Edge',
    'ios': 'iOS',
  };
  if (brand.containsKey(choice)) return brand[choice]!;
  if (choice.isEmpty) return choice;
  return '${choice[0].toUpperCase()}${choice.substring(1)}';
}

// ---------------------------------------------------------------------------
// IDLE
// ---------------------------------------------------------------------------

class _IdlePanel extends StatelessWidget {
  const _IdlePanel({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final int minutes = (ConnectionFixer.estimated.inSeconds / 60).ceil();

    return ListView(
      padding: const EdgeInsets.all(NovaSpace.xl),
      children: <Widget>[
        // Calm explainer: what this does and why it takes a moment.
        NovaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              NovaEyebrow(s.fixIntroEyebrow),
              const SizedBox(height: NovaSpace.md),
              Text(
                s.fixIntroTitle,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: NovaSpace.sm),
              Text(
                s.fixIntroBody,
                style: text.bodyMedium?.copyWith(color: nova.muted, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(height: NovaSpace.lg),

        // Prominent, helpful (not scary) time notice, same warning-tinted
        // recipe as the speed-test "not connected" banner.
        Container(
          padding: const EdgeInsets.all(NovaSpace.lg),
          decoration: BoxDecoration(
            color: nova.warning.withValues(alpha: 0.12),
            borderRadius: NovaRadii.smR,
            border: Border.all(color: nova.warning.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.schedule_rounded, size: 20, color: nova.warning),
                  const SizedBox(width: NovaSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          s.fixNoticeTitle,
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.fixNoticeBody,
                          style: text.bodySmall
                              ?.copyWith(color: nova.muted, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.md),
              Divider(height: 1, color: nova.warning.withValues(alpha: 0.25)),
              const SizedBox(height: NovaSpace.md),
              Row(
                children: <Widget>[
                  Icon(Icons.timelapse_rounded, size: 16, color: nova.muted),
                  const SizedBox(width: NovaSpace.sm),
                  Text(
                    s.fixEstimateLabel,
                    style: text.labelMedium?.copyWith(color: nova.muted),
                  ),
                  const Spacer(),
                  Text(
                    s.fixEstimateMinutes(minutes),
                    style: text.labelLarge?.copyWith(
                      color: nova.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: NovaSpace.xl),

        NovaButton(
          label: s.fixStart,
          icon: Icons.play_arrow_rounded,
          expand: true,
          onPressed: onStart,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// RUNNING
// ---------------------------------------------------------------------------

class _RunningPanel extends StatelessWidget {
  const _RunningPanel({
    required this.progress,
    required this.results,
    required this.applying,
    required this.cancelling,
    required this.onCancel,
  });

  final FixProgress? progress;
  final Map<int, FixResult> results;
  final bool applying;
  final bool cancelling;
  final VoidCallback onCancel;

  _StepState _statusFor(int i) {
    final FixResult? r = results[i];
    if (r != null) return r.reachable ? _StepState.reachable : _StepState.blocked;
    if (!applying && progress?.index == i) return _StepState.active;
    return _StepState.pending;
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    final FixProgress? p = progress;
    final int total = p?.total ?? ConnectionFixer.candidates.length;
    final int step = (p?.index ?? 0) + 1;
    final String fpLabel = _fpLabel(p?.fingerprint ?? '', s);
    final bool probing = p?.phase == 'probing';

    final String headline =
        applying ? s.fixApplying(fpLabel) : s.fixTrying(fpLabel);
    final String? phaseLabel = applying
        ? null
        : (probing ? s.fixPhaseChecking : s.fixPhaseConnecting);

    return ListView(
      padding: const EdgeInsets.all(NovaSpace.xl),
      children: <Widget>[
        NovaEyebrow(s.fixIntroEyebrow),
        const SizedBox(height: NovaSpace.md),

        // Live headline: the setup being tested (or applied) right now. Fades
        // between fingerprints so the state never reads as stuck.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (Widget child, Animation<double> anim) {
            return FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1).animate(anim),
                child: child,
              ),
            );
          },
          child: Text(
            headline,
            key: ValueKey<String>('head-$headline'),
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (!applying) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            s.fixStepOf(step, total),
            style: text.bodyMedium?.copyWith(color: nova.muted),
          ),
        ],
        const SizedBox(height: NovaSpace.lg),

        // Indeterminate bar: continuous motion keeps the screen alive.
        ClipRRect(
          borderRadius: NovaRadii.pillR,
          child: LinearProgressIndicator(
            minHeight: 6,
            backgroundColor: nova.surface2,
            valueColor: AlwaysStoppedAnimation<Color>(nova.cyan),
          ),
        ),
        if (phaseLabel != null) ...<Widget>[
          const SizedBox(height: NovaSpace.md),
          Row(
            children: <Widget>[
              Icon(
                probing ? Icons.travel_explore_rounded : Icons.sync_rounded,
                size: 16,
                color: nova.cyan,
              ),
              const SizedBox(width: NovaSpace.sm),
              Text(
                phaseLabel,
                style: text.bodySmall
                    ?.copyWith(color: nova.text, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
        const SizedBox(height: NovaSpace.lg),

        // The full run, laid out as a stepper so "it tests every setup and
        // reconnects several times" is visible, not just implied.
        NovaCard(
          child: Column(
            children: <Widget>[
              for (int i = 0;
                  i < ConnectionFixer.candidates.length;
                  i++) ...<Widget>[
                if (i > 0) const SizedBox(height: NovaSpace.md),
                _StepRow(
                  label: _fpLabel(ConnectionFixer.candidates[i], s),
                  state: _statusFor(i),
                  latencyMs: results[i]?.latencyMs,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: NovaSpace.xl),

        NovaButton(
          label: cancelling ? s.fixCancelling : s.fixCancel,
          icon: Icons.close_rounded,
          variant: NovaButtonVariant.secondary,
          expand: true,
          loading: cancelling,
          onPressed: cancelling ? null : onCancel,
        ),
        const SizedBox(height: NovaSpace.md),
        Text(
          s.fixKeepOpen,
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: nova.muted),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state, this.latencyMs});

  final String label;
  final _StepState state;
  final int? latencyMs;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    final (Color, String) trailing = switch (state) {
      _StepState.reachable => (nova.successStrong, '${latencyMs ?? 0} ms'),
      _StepState.active => (nova.cyan, s.fixStepActive),
      _StepState.blocked => (nova.muted, s.fixStepBlocked),
      _StepState.pending => (nova.muted, s.fixStepPending),
    };

    final bool emphasize =
        state == _StepState.active || state == _StepState.reachable;

    return Row(
      children: <Widget>[
        _StepGlyph(state: state),
        const SizedBox(width: NovaSpace.md),
        Expanded(
          child: Text(
            label,
            style: text.bodyMedium?.copyWith(
              color: emphasize ? nova.text : nova.muted,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          trailing.$2,
          style: text.labelMedium?.copyWith(
            color: trailing.$1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _StepGlyph extends StatelessWidget {
  const _StepGlyph({required this.state});
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    const double box = 22;

    switch (state) {
      case _StepState.active:
        return SizedBox(
          width: box,
          height: box,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: nova.cyan,
              ),
            ),
          ),
        );
      case _StepState.reachable:
        return Container(
          width: box,
          height: box,
          decoration: BoxDecoration(
            color: nova.successStrong.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_rounded, size: 14, color: nova.successStrong),
        );
      case _StepState.blocked:
        return SizedBox(
          width: box,
          height: box,
          child: Icon(Icons.remove_rounded, size: 16, color: nova.muted),
        );
      case _StepState.pending:
        return Center(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: nova.borderStrong),
            ),
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// RESULT
// ---------------------------------------------------------------------------

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.outcome,
    required this.onRetry,
    required this.onClose,
  });

  final FixOutcome outcome;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    final Widget testedList = _RankedList(
      results: outcome.results,
      best: outcome.best,
    );

    if (outcome.success) {
      final String fp = _fpLabel(outcome.best ?? '', s);
      return ListView(
        padding: const EdgeInsets.all(NovaSpace.xl),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(NovaSpace.xl),
            decoration: BoxDecoration(
              color: nova.successStrong.withValues(alpha: 0.12),
              borderRadius: NovaRadii.cardR,
              border:
                  Border.all(color: nova.successStrong.withValues(alpha: 0.35)),
            ),
            child: Column(
              children: <Widget>[
                Icon(Icons.verified_user_rounded,
                    size: 44, color: nova.successStrong),
                const SizedBox(height: NovaSpace.md),
                Text(
                  s.fixSuccessTitle,
                  textAlign: TextAlign.center,
                  style: text.titleMedium?.copyWith(color: nova.muted),
                ),
                const SizedBox(height: 4),
                Text(
                  fp,
                  textAlign: TextAlign.center,
                  style: text.headlineSmall?.copyWith(
                    color: nova.successStrong,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: NovaSpace.sm),
                Text(
                  s.fixSuccessBody,
                  textAlign: TextAlign.center,
                  style:
                      text.bodyMedium?.copyWith(color: nova.muted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.lg),
          testedList,
          const SizedBox(height: NovaSpace.xl),
          NovaButton(
            label: s.fixDone,
            icon: Icons.check_rounded,
            expand: true,
            onPressed: onClose,
          ),
        ],
      );
    }

    // Honest failure: informative, not alarming. Still shows the tested list so
    // the user can see every setup was tried.
    return ListView(
      padding: const EdgeInsets.all(NovaSpace.xl),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(NovaSpace.xl),
          decoration: BoxDecoration(
            color: nova.surface,
            borderRadius: NovaRadii.cardR,
            border: Border.all(color: nova.border),
          ),
          child: Column(
            children: <Widget>[
              Icon(Icons.report_gmailerrorred_rounded,
                  size: 44, color: nova.warning),
              const SizedBox(height: NovaSpace.md),
              Text(
                s.fixFailTitle,
                textAlign: TextAlign.center,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: NovaSpace.sm),
              Text(
                s.fixFailBody,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: nova.muted, height: 1.4),
              ),
            ],
          ),
        ),
        if (outcome.results.isNotEmpty) ...<Widget>[
          const SizedBox(height: NovaSpace.lg),
          testedList,
        ],
        const SizedBox(height: NovaSpace.xl),
        NovaButton(
          label: s.fixTryAgain,
          icon: Icons.refresh_rounded,
          expand: true,
          onPressed: onRetry,
        ),
        const SizedBox(height: NovaSpace.md),
        NovaButton(
          label: s.fixClose,
          variant: NovaButtonVariant.ghost,
          expand: true,
          onPressed: onClose,
        ),
      ],
    );
  }
}

/// The ranked results table (best-first), with the winner highlighted.
class _RankedList extends StatelessWidget {
  const _RankedList({required this.results, required this.best});

  final List<FixResult> results;
  final String? best;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.fixTestedEyebrow),
          const SizedBox(height: NovaSpace.md),
          for (int i = 0; i < results.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: NovaSpace.sm),
            _RankRow(
              result: results[i],
              winner: best != null && results[i].fingerprint == best,
            ),
          ],
        ],
      ),
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({required this.result, required this.winner});

  final FixResult result;
  final bool winner;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final bool reachable = result.reachable;
    final String label = _fpLabel(result.fingerprint, s);

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: NovaSpace.md, vertical: NovaSpace.sm),
      decoration: winner
          ? BoxDecoration(
              color: nova.successStrong.withValues(alpha: 0.10),
              borderRadius: NovaRadii.smR,
              border:
                  Border.all(color: nova.successStrong.withValues(alpha: 0.30)),
            )
          : null,
      child: Row(
        children: <Widget>[
          Icon(
            reachable ? Icons.check_circle_rounded : Icons.remove_circle_outline,
            size: 18,
            color: reachable ? nova.successStrong : nova.muted,
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(
                color: reachable ? nova.text : nova.muted,
                fontWeight: winner ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          if (winner) ...<Widget>[
            _WinnerBadge(label: s.fixWinnerBadge),
            const SizedBox(width: NovaSpace.sm),
          ],
          Text(
            reachable ? '${result.latencyMs} ms' : s.fixStepBlocked,
            style: text.labelMedium?.copyWith(
              color: reachable ? nova.successStrong : nova.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _WinnerBadge extends StatelessWidget {
  const _WinnerBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: nova.successStrong.withValues(alpha: 0.16),
        borderRadius: NovaRadii.pillR,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: nova.successStrong,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
