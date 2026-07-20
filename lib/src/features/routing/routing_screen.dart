import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/proxy/singbox/singbox_config.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../settings/settings_controller.dart';

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
                if (_isDesktop) ...<Widget>[
                  const SizedBox(height: NovaSpace.lg),
                  NovaCard(
                    padding: EdgeInsets.zero,
                    child: _RuleSwitch(
                      icon: Icons.devices_rounded,
                      title: s.routeTun,
                      subtitle: s.routeTunSub,
                      value: settings.tunMode,
                      onChanged: settings.setTunMode,
                    ),
                  ),
                ],
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
