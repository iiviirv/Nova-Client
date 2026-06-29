import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../cloudflare/deploy_screen.dart';

/// The scrollable Servers content — search, protocol filters, and the list of
/// configs styled as native server rows (flag/icon, name, protocol badge,
/// latency + signal bars, selected check). Shared by the Servers tab and the
/// Home screen's "Configs" segment. With an empty list it shows the native
/// three-action empty state (Deploy / Panel / Add).
class ServersBody extends StatefulWidget {
  const ServersBody({super.key, this.compact = false});

  /// Embedded in the Home "Configs" tab — drops its own scroll/padding so it
  /// nests inside the dashboard's ListView.
  final bool compact;

  @override
  State<ServersBody> createState() => _ServersBodyState();
}

class _ServersBodyState extends State<ServersBody> {
  String _query = '';
  ProxyKind? _filter; // null = All

  @override
  Widget build(BuildContext context) {
    final profiles = NovaScope.of(context).profiles;

    return ListenableBuilder(
      listenable: profiles,
      builder: (context, _) {
        final List<ProxyProfile> all = profiles.profiles;
        final List<ProxyProfile> shown = all.where((p) {
          if (_filter != null && p.kind != _filter) return false;
          if (_query.isEmpty) return true;
          return p.name.toLowerCase().contains(_query.toLowerCase());
        }).toList();

        if (all.isEmpty) {
          return _EmptyState(compact: widget.compact);
        }

        final List<ProxyKind> kinds =
            all.map((p) => p.kind).toSet().toList();

        final List<Widget> children = <Widget>[
          if (!widget.compact) ...<Widget>[
            _SearchField(onChanged: (v) => setState(() => _query = v)),
            const SizedBox(height: 12),
          ],
          if (kinds.length > 1) ...<Widget>[
            _FilterChips(
              kinds: kinds,
              selected: _filter,
              onChanged: (k) => setState(() => _filter = k),
            ),
            const SizedBox(height: 12),
          ],
          for (final p in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ServerRow(
                profile: p,
                active: p.id == profiles.activeId,
                onSelect: () => profiles.setActive(p.id),
                onDelete: () => profiles.remove(p.id),
              ),
            ),
        ];

        if (widget.compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: children,
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return TextField(
      onChanged: onChanged,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: 'Search servers',
        prefixIcon: Icon(Icons.search, color: nova.muted, size: 20),
        filled: true,
        fillColor: nova.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: NovaRadii.tabR,
          borderSide: BorderSide(color: nova.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NovaRadii.tabR,
          borderSide: BorderSide(color: nova.border),
        ),
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.kinds,
    required this.selected,
    required this.onChanged,
  });

  final List<ProxyKind> kinds;
  final ProxyKind? selected;
  final ValueChanged<ProxyKind?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          NovaPill(
            label: 'All',
            selected: selected == null,
            onTap: () => onChanged(null),
          ),
          for (final k in kinds) ...<Widget>[
            const SizedBox(width: 8),
            NovaPill(
              label: k.label,
              selected: selected == k,
              onTap: () => onChanged(k),
            ),
          ],
        ],
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
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
    final text = Theme.of(context).textTheme;
    final int? latency = profile.lastLatencyMs;

    return GestureDetector(
      onTap: onSelect,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: active ? nova.cyan.withValues(alpha: 0.08) : nova.surface,
          borderRadius: NovaRadii.cardR,
          border: Border.all(
            color: active ? nova.cyan.withValues(alpha: 0.5) : nova.border,
          ),
        ),
        child: Row(
          children: <Widget>[
            NovaIconChip(
              icon: profile.isSubscription
                  ? Icons.cloud_sync_rounded
                  : Icons.vpn_key_rounded,
              color: active ? nova.cyan : nova.indigo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(profile.name,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      NovaProtocolBadge(
                        label: profile.kind.label,
                        color: nova.cyan,
                      ),
                      if (profile.isSubscription) ...<Widget>[
                        const SizedBox(width: 8),
                        Text('${profile.nodeCount} nodes',
                            style: text.labelSmall?.copyWith(color: nova.muted)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (latency != null) ...<Widget>[
              Text('$latency ms',
                  style: text.labelMedium?.copyWith(
                    color: NovaSemantics.ping(latency),
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(width: 8),
              NovaSignalBars(latencyMs: latency),
              const SizedBox(width: 10),
            ],
            if (active)
              Icon(Icons.check_circle_rounded, color: nova.cyan, size: 22)
            else
              GestureDetector(
                onTap: onDelete,
                child: Icon(Icons.delete_outline_rounded,
                    color: nova.muted, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

/// Three-action empty state mirroring the native `ServersEmptyState`.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: NovaGradients.logo,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 16),
        Text('No servers yet',
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Deploy your own panel, sign in to one, or add a config to get started.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: nova.muted)),
        const SizedBox(height: 20),
        _EmptyAction(
          icon: Icons.cloud_upload_rounded,
          title: 'Deploy your own panel',
          subtitle: 'Spin up a free Nova worker on Cloudflare',
          highlighted: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeployScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _EmptyAction(
          icon: Icons.login_rounded,
          title: 'Sign in to your panel',
          subtitle: 'Import configs from an existing panel',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CloudflareScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _EmptyAction(
          icon: Icons.add_rounded,
          title: 'Add a config',
          subtitle: 'Paste a vless:// link or subscription URL',
          onTap: () => showAddServerDialog(context),
        ),
      ],
    );

    if (compact) return content;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: <Widget>[content],
    );
  }
}

class _EmptyAction extends StatelessWidget {
  const _EmptyAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: highlighted ? nova.cyan.withValues(alpha: 0.08) : nova.surface,
          borderRadius: NovaRadii.cardR,
          border: Border.all(
            color: highlighted ? nova.cyan.withValues(alpha: 0.5) : nova.border,
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                gradient: NovaGradients.logo,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: text.bodySmall?.copyWith(color: nova.muted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: nova.muted),
          ],
        ),
      ),
    );
  }
}

/// Add-config dialog: name + URI + protocol kind. Shared entry point used by
/// the Servers screen header and the empty state.
Future<void> showAddServerDialog(BuildContext context) async {
  final profiles = NovaScope.of(context).profiles;
  final s = NovaStrings.of(context);
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController uriCtrl = TextEditingController();
  ProxyKind kind = ProxyKind.subscription;

  final bool? added = await showDialog<bool>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            backgroundColor: context.nova.bgAlt,
            shape: const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
            title: Text(s.add, style: Theme.of(context).textTheme.titleLarge),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(hintText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: uriCtrl,
                  decoration: const InputDecoration(
                      hintText: 'vless://…  or  https://…/sub'),
                ),
                const SizedBox(height: 12),
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
                          onTap: () => setLocal(() => kind = k),
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
          ? 'Server ${profiles.profiles.length + 1}'
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
