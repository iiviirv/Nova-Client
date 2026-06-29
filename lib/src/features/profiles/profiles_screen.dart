import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../cloudflare/cloudflare_screen.dart';
import 'profiles_controller.dart';

/// Manages connection profiles — single links and Nova subscriptions. Selecting
/// a profile here makes it the dashboard's active connection target.
class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ProfilesController profiles = NovaScope.of(context).profiles;
    final s = NovaStrings.of(context);

    return ListenableBuilder(
      listenable: profiles,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: ListView(
              padding: const EdgeInsets.all(NovaSpace.xl),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(s.navProfiles,
                        style: Theme.of(context).textTheme.headlineMedium),
                    const Spacer(),
                    NovaButton(
                      label: s.add,
                      icon: Icons.add,
                      onPressed: () => _showAddDialog(context, profiles, s),
                    ),
                  ],
                ),
                const SizedBox(height: NovaSpace.lg),
                NovaCard(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const CloudflareScreen()),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.cloud_outlined, color: context.nova.cyan),
                      const SizedBox(width: NovaSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Connect Cloudflare',
                                style: Theme.of(context).textTheme.titleSmall),
                            Text('Deploy your own panel or import your configs',
                                style: TextStyle(color: context.nova.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: context.nova.muted),
                    ],
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                for (final p in profiles.profiles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NovaSpace.md),
                    child: _ProfileCard(
                      profile: p,
                      active: p.id == profiles.activeId,
                      onSelect: () => profiles.setActive(p.id),
                      onDelete: () => profiles.remove(p.id),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAddDialog(
    BuildContext context,
    ProfilesController profiles,
    NovaStrings s,
  ) async {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController uriCtrl = TextEditingController();
    ProxyKind kind = ProxyKind.subscription;

    final bool? added = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: context.nova.bgAlt,
              shape:
                  const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
              title: Text(s.add,
                  style: Theme.of(context).textTheme.titleLarge),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(hintText: 'Name'),
                  ),
                  const SizedBox(height: NovaSpace.md),
                  TextField(
                    controller: uriCtrl,
                    decoration: const InputDecoration(
                        hintText: 'vless://…  or  https://…/sub'),
                  ),
                  const SizedBox(height: NovaSpace.md),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final k in ProxyKind.values)
                          NovaPill(
                            label: k.label,
                            selected: kind == k,
                            onTap: () => setState(() => kind = k),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(s.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(s.save),
                ),
              ],
            );
          },
        );
      },
    );

    if (added == true && uriCtrl.text.trim().isNotEmpty) {
      final String uri = uriCtrl.text.trim();
      profiles.add(ProxyProfile(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: nameCtrl.text.trim().isEmpty
            ? 'Profile ${profiles.profiles.length + 1}'
            : nameCtrl.text.trim(),
        kind: kind,
        uri: kind == ProxyKind.subscription ? '' : uri,
        subscriptionUrl: kind == ProxyKind.subscription ? uri : null,
        updatedAt: DateTime.now(),
      ));
    }
    nameCtrl.dispose();
    uriCtrl.dispose();
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.active,
    required this.onSelect,
    required this.onDelete,
  });

  final ProxyProfile profile;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return NovaCard(
      raised: active,
      borderColor: active ? nova.cyan.withValues(alpha: 0.5) : null,
      onTap: onSelect,
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: nova.surface2,
              borderRadius: NovaRadii.smR,
            ),
            child: Icon(
              profile.isSubscription ? Icons.cloud_sync : Icons.vpn_key,
              color: active ? nova.cyan : nova.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(profile.name,
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Text(profile.kind.label,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: nova.cyan)),
                    if (profile.isSubscription) ...<Widget>[
                      Text('  ·  ${profile.nodeCount} nodes',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: nova.muted)),
                    ],
                    if (profile.lastLatencyMs != null) ...<Widget>[
                      Text('  ·  ${profile.lastLatencyMs} ms',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: nova.success)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (active)
            Icon(Icons.check_circle, color: nova.cyan, size: 20)
          else
            IconButton(
              icon: Icon(Icons.delete_outline, color: nova.muted, size: 18),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}
