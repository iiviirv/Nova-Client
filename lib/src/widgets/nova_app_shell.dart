import 'package:flutter/material.dart';

import '../features/cloudflare/cloudflare_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/profiles/profiles_screen.dart';
import '../features/radar/radar_screen.dart';
import '../features/routing/routing_screen.dart';
import '../features/settings/settings_screen.dart';
import '../l10n/nova_strings.dart';
import '../theme/nova_theme.dart';
import 'nova_logo.dart';

/// The top-level navigation scaffold. Adapts between a bottom navigation bar on
/// narrow (mobile) layouts and a navigation rail on wide (desktop/tablet)
/// layouts — both styled in the Nova language.
class NovaAppShell extends StatefulWidget {
  const NovaAppShell({super.key, this.startAction});

  /// One-time action picked during onboarding: 'deploy' | 'panel' | 'add'.
  final String? startAction;

  @override
  State<NovaAppShell> createState() => _NovaAppShellState();
}

class _NovaAppShellState extends State<NovaAppShell> {
  int _index = 0;

  static const List<Widget> _screens = <Widget>[
    DashboardScreen(),
    ProfilesScreen(),
    RadarScreen(),
    RoutingScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    final String? action = widget.startAction;
    if (action == null) return;
    // Land where the onboarding choice points.
    _index = 1; // Configs/Profiles
    if (action == 'deploy' || action == 'panel') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CloudflareScreen()),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;

    final List<_Dest> dests = <_Dest>[
      _Dest(Icons.shield_outlined, Icons.shield, s.navDashboard),
      _Dest(Icons.layers_outlined, Icons.layers, s.navProfiles),
      _Dest(Icons.radar_outlined, Icons.radar, s.navRadar),
      _Dest(Icons.route_outlined, Icons.route, s.navRouting),
      _Dest(Icons.settings_outlined, Icons.settings, s.navSettings),
    ];

    final Widget body = SafeArea(
      child: IndexedStack(index: _index, children: _screens),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool wide = constraints.maxWidth >= 760;
        if (wide) {
          return Scaffold(
            body: Row(
              children: <Widget>[
                _NovaRail(
                  index: _index,
                  dests: dests,
                  onSelect: (i) => setState(() => _index = i),
                ),
                VerticalDivider(width: 1, color: nova.border),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: _NovaBottomBar(
            index: _index,
            dests: dests,
            onSelect: (i) => setState(() => _index = i),
          ),
        );
      },
    );
  }
}

class _Dest {
  const _Dest(this.icon, this.activeIcon, this.label);
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

class _NovaBottomBar extends StatelessWidget {
  const _NovaBottomBar({
    required this.index,
    required this.dests,
    required this.onSelect,
  });

  final int index;
  final List<_Dest> dests;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      decoration: BoxDecoration(
        color: nova.navBg,
        border: Border(top: BorderSide(color: nova.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < dests.length; i++)
                Expanded(
                  child: _NavItem(
                    dest: dests[i],
                    selected: i == index,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.dest,
    required this.selected,
    required this.onTap,
  });

  final _Dest dest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color color = selected ? nova.cyan : nova.muted;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(selected ? dest.activeIcon : dest.icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            dest.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

class _NovaRail extends StatelessWidget {
  const _NovaRail({
    required this.index,
    required this.dests,
    required this.onSelect,
  });

  final int index;
  final List<_Dest> dests;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      width: 88,
      color: nova.bgAlt,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 20),
          const NovaLogoBadge(size: 44),
          const SizedBox(height: 24),
          for (int i = 0; i < dests.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _RailItem(
                dest: dests[i],
                selected: i == index,
                onTap: () => onSelect(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.dest,
    required this.selected,
    required this.onTap,
  });

  final _Dest dest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color color = selected ? nova.cyan : nova.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? nova.cyan.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(14),
          border: selected
              ? Border.all(color: nova.cyan.withValues(alpha: 0.4))
              : null,
        ),
        child: Column(
          children: <Widget>[
            Icon(selected ? dest.activeIcon : dest.icon, color: color),
            const SizedBox(height: 6),
            Text(
              dest.label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
