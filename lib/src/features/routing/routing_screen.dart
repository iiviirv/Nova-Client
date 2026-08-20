import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/proxy/isp_optimizer.dart';
import '../../core/proxy/singbox/singbox_config.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../settings/settings_controller.dart';
import '../tuner/fix_connection_screen.dart';

/// Whether the full-device TUN option applies (it is a desktop-only data path).
final bool _isDesktop =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Routing mode, rule toggles, and DNS resolver. These compile into the
/// sing-box config the core runs, so the choices here actually change how
/// traffic is routed and resolved (persisted via [SettingsController]).
class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final SettingsController settings = NovaScope.of(context).settings;

    // A themed Scaffold is required: this is a pushed route, and without one it
    // renders with no background (black) so the light theme never shows — the
    // "Rules & DNS stuck in dark mode" report. The Scaffold gives it the app's
    // real background plus a back button.
    return Scaffold(
      appBar: AppBar(title: Text(s.navRouting)),
      body: ListenableBuilder(
        listenable: settings,
        builder: (BuildContext context, _) {
          return Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
              child: ListView(
                padding: const EdgeInsets.all(NovaSpace.xl),
                children: <Widget>[
                  Text(s.navRouting,
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: NovaSpace.lg),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      NovaEyebrow(s.routeMode),
                      const SizedBox(height: NovaSpace.md),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final SingboxMode m in SingboxMode.values)
                            NovaPill(
                              label: m.label(s),
                              icon: m.icon,
                              selected: settings.mode == m,
                              onTap: () => settings.setMode(m),
                            ),
                        ],
                      ),
                      const SizedBox(height: NovaSpace.sm),
                      Text(settings.mode.description(s),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: nova.muted)),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),
                NovaCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      _RuleSwitch(
                        icon: Icons.block,
                        title: s.routeBlockAds,
                        subtitle: s.routeBlockAdsSub,
                        value: settings.blockAds,
                        onChanged: settings.setBlockAds,
                      ),
                      Divider(height: 1, color: nova.border),
                      _RuleSwitch(
                        icon: Icons.flag_outlined,
                        title: s.routeDirectIran,
                        subtitle: s.routeDirectIranSub,
                        value: settings.bypassIran,
                        onChanged: settings.setBypassIran,
                      ),
                      Divider(height: 1, color: nova.border),
                      _RuleSwitch(
                        icon: Icons.lan_outlined,
                        title: s.routeBypassLan,
                        subtitle: s.routeBypassLanSub,
                        value: settings.bypassLan,
                        onChanged: settings.setBypassLan,
                      ),
                    ],
                  ),
                ),
                if (!_isDesktop) ...<Widget>[
                  const SizedBox(height: NovaSpace.lg),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: _RuleSwitch(
                      icon: Icons.speed_rounded,
                      title: s.routeAutoIsp,
                      subtitle: s.routeAutoIspSub,
                      value: settings.autoOptimizeCarrier,
                      onChanged: settings.setAutoOptimizeCarrier,
                    ),
                  ),
                ],
                if (_isDesktop) ...<Widget>[
                  const SizedBox(height: NovaSpace.lg),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _RuleSwitch(
                          icon: Icons.devices_rounded,
                          title: s.routeTun,
                          subtitle: s.routeTunSub,
                          value: settings.tunMode,
                          onChanged: settings.setTunMode,
                        ),
                        if (!settings.tunMode)
                          _RuleSwitch(
                            icon: Icons.settings_ethernet_rounded,
                            title: s.routeSysProxy,
                            subtitle: s.routeSysProxySub,
                            value: settings.autoSystemProxy,
                            onChanged: settings.setAutoSystemProxy,
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: NovaSpace.lg),
                const _ConnectionTuningCard(),
                const SizedBox(height: NovaSpace.lg),
                _UrlTestCard(settings: settings),
                const SizedBox(height: NovaSpace.lg),
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      NovaEyebrow(s.routeDns),
                      const SizedBox(height: NovaSpace.md),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final NovaDnsChoice d in kNovaDnsChoices)
                            NovaPill(
                              label: d.label,
                              selected: settings.dns == d.server,
                              onTap: () => settings.setDns(d.server),
                            ),
                        ],
                      ),
                      const SizedBox(height: NovaSpace.sm),
                      Text(
                        s.routeDnsSub,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: nova.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                // Hysteria2 "speed boost" = Brutal congestion control. Preset
                // line-speed pills keep it safe (sane values) and simple.
                NovaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      NovaEyebrow(s.routeSpeedTitle),
                      const SizedBox(height: NovaSpace.md),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final ({int down, int up, String label}) p
                              in _hy2Presets(s))
                            NovaPill(
                              label: p.label,
                              selected: settings.hy2DownMbps == p.down &&
                                  settings.hy2UpMbps == p.up,
                              onTap: () => settings.setHy2Bandwidth(
                                  downMbps: p.down, upMbps: p.up),
                            ),
                        ],
                      ),
                      const SizedBox(height: NovaSpace.sm),
                      Text(
                        s.routeSpeedSub,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: nova.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                Container(
                  padding: const EdgeInsets.all(NovaSpace.md),
                  decoration: BoxDecoration(
                    color: nova.info.withValues(alpha: 0.10),
                    borderRadius: NovaRadii.smR,
                    border: Border.all(color: nova.info.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.info_outline, size: 18, color: nova.info),
                      const SizedBox(width: NovaSpace.sm),
                      Expanded(
                        child: Text(
                          s.routeApplyNote,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: nova.muted),
                        ),
                      ),
                    ],
                  ),
                ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Safe line-speed presets for the Hysteria2 boost. Off = BBR; the rest set an
/// asymmetric down/up (typical home links) so Brutal has sane values without a
/// free-form field the user could set to an absurd rate.
List<({int down, int up, String label})> _hy2Presets(NovaStrings s) =>
    <({int down, int up, String label})>[
      (down: 0, up: 0, label: s.routeSpeedOff),
      (down: 25, up: 6, label: '25 Mbps'),
      (down: 50, up: 12, label: '50 Mbps'),
      (down: 100, up: 25, label: '100 Mbps'),
      (down: 200, up: 50, label: '200 Mbps'),
    ];

extension _RouteModeMeta on SingboxMode {
  String label(NovaStrings s) => switch (this) {
        SingboxMode.rule => s.routeModeRule,
        SingboxMode.global => s.routeModeGlobal,
        SingboxMode.direct => s.routeModeDirect,
      };
  IconData get icon => switch (this) {
        SingboxMode.rule => Icons.alt_route,
        SingboxMode.global => Icons.public,
        SingboxMode.direct => Icons.arrow_forward,
      };
  String description(NovaStrings s) => switch (this) {
        SingboxMode.rule => s.routeModeRuleDesc,
        SingboxMode.global => s.routeModeGlobalDesc,
        SingboxMode.direct => s.routeModeDirectDesc,
      };
}

class _RuleSwitch extends StatelessWidget {
  const _RuleSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, color: nova.cyan),
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(subtitle,
          style:
              Theme.of(context).textTheme.bodySmall?.copyWith(color: nova.muted)),
    );
  }
}

/// Latin brand labels for the uTLS fingerprints. Brand names stay Latin in both
/// locales; only 'Auto' and 'Randomized' are localized (handled in [_fpLabel]).
const Map<String, String> _kFpBrand = <String, String>{
  'chrome': 'Chrome',
  'firefox': 'Firefox',
  'safari': 'Safari',
  'ios': 'iOS',
  'edge': 'Edge',
};

String _fpLabel(String choice, NovaStrings s) {
  if (choice.isEmpty) return s.routeTuneAuto;
  if (choice == 'randomized') return s.routeTuneRandomized;
  return _kFpBrand[choice] ??
      (choice.isEmpty
          ? choice
          : '${choice[0].toUpperCase()}${choice.substring(1)}');
}

/// "Connection tuning" / anti-censorship section: surfaces which uTLS
/// fingerprint is protecting the user right now, and lets them override the
/// automatic per-carrier pick. Stateful only so it can run [IspOptimizer.resolve]
/// (async) and cache the result for the status readout.
class _ConnectionTuningCard extends StatefulWidget {
  const _ConnectionTuningCard();

  @override
  State<_ConnectionTuningCard> createState() => _ConnectionTuningCardState();
}

class _ConnectionTuningCardState extends State<_ConnectionTuningCard> {
  SettingsController? _settings;
  IspMatch? _match;

  // The last enabled state we resolved for, so a rebuild that did not flip the
  // auto-optimize toggle does not kick off a redundant carrier lookup.
  bool? _resolvedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final SettingsController s = NovaScope.of(context).settings;
    if (!identical(s, _settings)) {
      _settings?.removeListener(_onSettingsChanged);
      _settings = s;
      s.addListener(_onSettingsChanged);
    }
    _resolve();
  }

  void _onSettingsChanged() {
    // Rebuild so the picker selection + manual/auto status reflect a fingerprint
    // change immediately; _resolve() only re-detects the carrier when the
    // auto-optimize toggle actually flips (its own guard).
    if (mounted) setState(() {});
    _resolve();
  }

  Future<void> _resolve() async {
    final SettingsController? s = _settings;
    if (s == null) return;
    final bool enabled = s.autoOptimizeCarrier;
    // The carrier readout only depends on the toggle; the manual fingerprint is
    // read straight from settings in build(), so skip re-detecting for it.
    if (_match != null && enabled == _resolvedFor) return;
    _resolvedFor = enabled;
    final IspMatch m =
        await IspOptimizer.instance.resolve(enabled: enabled, host: null);
    if (!mounted) return;
    setState(() => _match = m);
  }

  @override
  void dispose() {
    _settings?.removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final SettingsController settings = NovaScope.of(context).settings;

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaEyebrow(s.routeTuneTitle),
          const SizedBox(height: NovaSpace.sm),
          Text(
            s.routeTuneSubtitle,
            style: text.bodySmall?.copyWith(color: nova.muted),
          ),
          const SizedBox(height: NovaSpace.lg),
          _buildStatus(context, s, settings),
          const SizedBox(height: NovaSpace.lg),
          Text(
            s.routeTunePickerLabel,
            style: text.labelMedium
                ?.copyWith(color: nova.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: NovaSpace.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String choice in kFingerprintChoices)
                NovaPill(
                  label: _fpLabel(choice, s),
                  icon: choice.isEmpty ? Icons.auto_awesome : null,
                  selected: settings.fingerprint == choice,
                  onTap: () => settings.setFingerprint(choice),
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(
            s.routeTunePickerHint,
            style: text.bodySmall?.copyWith(color: nova.muted),
          ),
          const SizedBox(height: NovaSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.speed_rounded, size: 16, color: nova.muted),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: Text(
                  s.routeTuneTestHint,
                  style: text.bodySmall?.copyWith(color: nova.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.md),
          Divider(height: 1, color: nova.border),
          const SizedBox(height: NovaSpace.sm),
          // Calm, secondary hand-off to the setup finder for anyone who wants
          // Nova to test the fingerprints and pick the best automatically.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InkWell(
              borderRadius: NovaRadii.smR,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const FixConnectionScreen()),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.travel_explore_rounded,
                        size: 16, color: nova.cyan),
                    const SizedBox(width: NovaSpace.sm),
                    Text(
                      s.fixTitle,
                      style: text.labelLarge?.copyWith(
                        color: nova.cyan,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The security "posture" panel: a tinted, hairline-bordered container (same
  /// treatment as the info-note at the bottom of the screen) whose accent turns
  /// green when a specific fingerprint is actively being applied.
  Widget _buildStatus(
      BuildContext context, NovaStrings s, SettingsController settings) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final IspMatch? match = _match;

    // Decide the readout from: manual override -> live carrier match -> default.
    final bool manual = settings.fingerprint.isNotEmpty;
    final bool carrier = !manual &&
        settings.autoOptimizeCarrier &&
        match != null &&
        match.source == 'carrier';

    final bool active = manual || carrier;
    final Color accent = active ? nova.successStrong : nova.info;
    final IconData icon =
        active ? Icons.verified_user_outlined : Icons.shield_outlined;

    final String headlineTemplate;
    final String emphasis;
    final String detail;
    if (manual) {
      headlineTemplate = s.routeTuneStatusManual;
      emphasis = _fpLabel(settings.fingerprint, s);
      detail = s.routeTuneStatusManualSub;
    } else if (carrier) {
      headlineTemplate = s.routeTuneStatusCarrier;
      emphasis = match.label;
      final String fp = _fpLabel(match.fingerprint ?? 'chrome', s);
      final String frag = (match.tlsFragment ?? false)
          ? s.routeTuneFragOn
          : s.routeTuneFragOff;
      detail = s.routeTuneStatusCarrierSub
          .replaceFirst('%s', fp)
          .replaceFirst('%s', frag);
    } else {
      headlineTemplate = s.routeTuneStatusDefault;
      emphasis = '';
      detail = s.routeTuneStatusDefaultSub;
    }

    final TextStyle baseStyle =
        text.bodyMedium?.copyWith(color: nova.text, fontWeight: FontWeight.w600) ??
            const TextStyle();
    final TextStyle emphStyle = baseStyle.copyWith(color: accent);

    return Container(
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: NovaRadii.smR,
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    children:
                        _headlineSpans(headlineTemplate, emphasis, emphStyle),
                  ),
                  style: baseStyle,
                ),
                const SizedBox(height: 2),
                Text(detail, style: text.bodySmall?.copyWith(color: nova.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Splits a "%s" template so the single emphasized token (carrier or
  /// fingerprint name) can carry the accent color. Templates with no token
  /// render as one plain span.
  List<InlineSpan> _headlineSpans(
      String template, String token, TextStyle emph) {
    if (token.isEmpty || !template.contains('%s')) {
      return <InlineSpan>[TextSpan(text: template)];
    }
    final List<String> parts = template.split('%s');
    final List<InlineSpan> spans = <InlineSpan>[];
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i]));
      if (i < parts.length - 1) {
        spans.add(TextSpan(text: token, style: emph));
      }
    }
    return spans;
  }
}

/// Settings > Routing > URL test: what every latency measurement fetches, how
/// long a node may take before it is "no response", how often the live
/// auto-select group re-tests, and how much faster a node must be before the
/// group switches. Shared by the tunnel's urltest group and the lightning
/// measuring core. Text fields commit on change; bad numbers are ignored.
class _UrlTestCard extends StatefulWidget {
  const _UrlTestCard({required this.settings});
  final SettingsController settings;

  @override
  State<_UrlTestCard> createState() => _UrlTestCardState();
}

class _UrlTestCardState extends State<_UrlTestCard> {
  late final TextEditingController _url =
      TextEditingController(text: widget.settings.urlTestUrl);
  late final TextEditingController _timeout =
      TextEditingController(text: '${widget.settings.urlTestTimeoutSec}');
  late final TextEditingController _interval =
      TextEditingController(text: '${widget.settings.urlTestIntervalSec}');
  late final TextEditingController _tolerance =
      TextEditingController(text: '${widget.settings.urlTestToleranceMs}');

  @override
  void dispose() {
    _url.dispose();
    _timeout.dispose();
    _interval.dispose();
    _tolerance.dispose();
    super.dispose();
  }

  Widget _num(BuildContext context, TextEditingController c, String label,
      String unit, String help, void Function(int) onChanged) {
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.only(top: NovaSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: label, suffixText: unit),
            onChanged: (String v) {
              final int? n = int.tryParse(v.trim());
              if (n != null) onChanged(n);
            },
          ),
          const SizedBox(height: 4),
          Text(help,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.urlTestTitle,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(s.urlTestSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: s.urlTestUrl,
              hintText: kDefaultUrlTestUrl,
            ),
            onChanged: widget.settings.setUrlTestUrl,
          ),
          const SizedBox(height: 4),
          Text(s.urlTestUrlHelp,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          _num(context, _timeout, s.urlTestTimeout, 's', s.urlTestTimeoutHelp,
              widget.settings.setUrlTestTimeoutSec),
          _num(context, _interval, s.urlTestInterval, 's',
              s.urlTestIntervalHelp, widget.settings.setUrlTestIntervalSec),
          _num(context, _tolerance, s.urlTestTolerance, 'ms',
              s.urlTestToleranceHelp, widget.settings.setUrlTestToleranceMs),
        ],
      ),
    );
  }
}
