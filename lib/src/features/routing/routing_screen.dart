import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';

/// Routing mode + ruleset overview. The routing engine (GeoIP / GeoSite rules,
/// per-app proxying) is delivered by the sing-box core; this screen presents
/// the user-facing controls that map onto it.
class RoutingScreen extends StatefulWidget {
  const RoutingScreen({super.key});

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  _RouteMode _mode = _RouteMode.rule;
  bool _blockAds = true;
  bool _bypassIran = true;
  bool _bypassLan = true;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
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
                  const NovaEyebrow('Mode'),
                  const SizedBox(height: NovaSpace.md),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final m in _RouteMode.values)
                        NovaPill(
                          label: m.label,
                          icon: m.icon,
                          selected: _mode == m,
                          onTap: () => setState(() => _mode = m),
                        ),
                    ],
                  ),
                  const SizedBox(height: NovaSpace.sm),
                  Text(_mode.description,
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
                    title: 'Block ads & trackers',
                    subtitle: 'Drops known ad/tracker domains',
                    value: _blockAds,
                    onChanged: (v) => setState(() => _blockAds = v),
                  ),
                  Divider(height: 1, color: nova.border),
                  _RuleSwitch(
                    icon: Icons.flag_outlined,
                    title: 'Direct for Iran (GeoIP/GeoSite)',
                    subtitle: 'Iranian destinations bypass the proxy',
                    value: _bypassIran,
                    onChanged: (v) => setState(() => _bypassIran = v),
                  ),
                  Divider(height: 1, color: nova.border),
                  _RuleSwitch(
                    icon: Icons.lan_outlined,
                    title: 'Bypass LAN',
                    subtitle: 'Private/local ranges stay direct',
                    value: _bypassLan,
                    onChanged: (v) => setState(() => _bypassLan = v),
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
                      'These rules compile into the sing-box routing config '
                      'when the core is connected.',
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
  }
}

enum _RouteMode { rule, global, direct }

extension _RouteModeMeta on _RouteMode {
  String get label => switch (this) {
        _RouteMode.rule => 'Rule-based',
        _RouteMode.global => 'Global',
        _RouteMode.direct => 'Direct',
      };
  IconData get icon => switch (this) {
        _RouteMode.rule => Icons.alt_route,
        _RouteMode.global => Icons.public,
        _RouteMode.direct => Icons.arrow_forward,
      };
  String get description => switch (this) {
        _RouteMode.rule =>
          'Smart routing — proxy what needs it, keep the rest direct.',
        _RouteMode.global => 'Route all traffic through the proxy.',
        _RouteMode.direct => 'No proxying — everything goes direct.',
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
