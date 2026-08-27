import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/singbox/awg_config.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../relay/relay_link.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_pill.dart';
import '../../core/util/format.dart';
import '../../core/proxy/health_store.dart';
import '../../core/proxy/list_freshness.dart';
import '../../core/proxy/subscription.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../widgets/nova_scope.dart';
import '../profiles/profiles_controller.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../cloudflare/deploy_screen.dart';
import '../vps/connect_vps_screen.dart';
import '../vps/vps_controller.dart';
import 'node_list_screen.dart';

/// Probe every profile once per app launch. [ServersBody] exists in both the
/// Home and Servers tabs, so this shared guard prevents duplicate network work.
final Set<String> _profileMetadataScheduled = <String>{};

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

  // Saved VPS panels, so a row backed by a connected VPS gets a "Manage" action
  // that opens its admin panel.
  List<VpsPanel> _vpsPanels = <VpsPanel>[];
  VpsController? _vps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final VpsController vps = NovaScope.of(context).vps;
    if (!identical(vps, _vps)) {
      _vps?.removeListener(_loadPanels);
      _vps = vps;
      _vps!.addListener(_loadPanels);
      _loadPanels();
    }
  }

  @override
  void dispose() {
    _vps?.removeListener(_loadPanels);
    super.dispose();
  }

  Future<void> _loadPanels() async {
    final List<VpsPanel> panels = await (_vps?.loadPanels() ??
        Future<List<VpsPanel>>.value(<VpsPanel>[]));
    if (mounted) setState(() => _vpsPanels = panels);
  }

  /// The saved VPS panel whose host matches this profile, or null.
  VpsPanel? _panelFor(ProxyProfile p) {
    final String host = _hostOf(p);
    if (host.isEmpty) return null;
    for (final VpsPanel panel in _vpsPanels) {
      final String ph = Uri.tryParse(panel.baseUrl)?.host ?? panel.id;
      if (ph == host || panel.id == host) return panel;
    }
    return null;
  }

  static String _hostOf(ProxyProfile p) {
    final String? sub = p.subscriptionUrl;
    if (sub != null && sub.isNotEmpty) {
      final String h = Uri.tryParse(sub)?.host ?? '';
      if (h.isNotEmpty) return h;
    }
    // vless://uuid@host:port?...
    final int at = p.uri.indexOf('@');
    if (at >= 0) {
      final String rest = p.uri.substring(at + 1);
      final Match? m = RegExp(r'[:/?#]').firstMatch(rest);
      return m != null ? rest.substring(0, m.start) : rest;
    }
    return Uri.tryParse(p.uri)?.host ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final profiles = NovaScope.of(context).profiles;

    return ListenableBuilder(
      listenable: profiles,
      builder: (context, _) {
        final List<ProxyProfile> all = profiles.profiles;
        for (final ProxyProfile profile in all) {
          _scheduleProfileMetadata(profiles, profile);
        }
        // A filter for a kind that no longer exists (the user filtered to
        // AmneziaWG, then deleted the only AmneziaWG config) would hide every
        // remaining profile while the chip that could clear it is gone too:
        // that read as "deleting my AWG config deleted my subscriptions".
        // Treat a stale filter as All.
        final ProxyKind? filter =
            (_filter != null && all.any((p) => p.kind == _filter))
                ? _filter
                : null;
        final List<ProxyProfile> shown = all.where((p) {
          if (filter != null && p.kind != filter) return false;
          if (_query.isEmpty) return true;
          return p.name.toLowerCase().contains(_query.toLowerCase());
        }).toList();

        if (all.isEmpty) {
          return _EmptyState(compact: widget.compact);
        }

        final List<ProxyKind> kinds = all.map((p) => p.kind).toSet().toList();

        final List<Widget> children = <Widget>[
          if (!widget.compact) ...<Widget>[
            _SearchField(onChanged: (v) => setState(() => _query = v)),
            const SizedBox(height: NovaSpace.sm),
          ],
          if (kinds.length > 1) ...<Widget>[
            _FilterChips(
              kinds: kinds,
              selected: filter,
              onChanged: (k) => setState(() => _filter = k),
            ),
            const SizedBox(height: NovaSpace.xs),
          ],
          for (final p in shown)
            Padding(
              // Keyed by profile id so a row's State (the open overflow menu,
              // for one) can never be handed to a neighbouring profile when the
              // list shifts underneath it.
              key: ValueKey<String>('server-row-${p.id}'),
              padding: const EdgeInsets.only(bottom: 10),
              child: _ServerRow(
                profile: p,
                active: p.id == profiles.activeId,
                onOpen: () => _open(context, p),
                onSelect: () => _select(context, p),
                onExtract: () => _openNodes(context, p),
                onEdit: () => _editProfile(context, profiles, p),
                onDelete: () => _confirmDelete(context, profiles, p),
                onManage: _panelFor(p) == null
                    ? null
                    : () => _vps!.openAdminFor(context, _panelFor(p)!),
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

  /// Row tap. A subscription opens its node/IP list (where you can see and pin
  /// an exit); a single config just becomes the active selection.
  void _open(BuildContext context, ProxyProfile p) {
    if (p.isSubscription) {
      _openNodes(context, p);
    } else {
      _select(context, p);
    }
  }

  /// Opens the node list for a subscription, showing each exit's IP:port and
  /// live latency so the user can pick one.
  void _openNodes(BuildContext context, ProxyProfile p) {
    final scope = NovaScope.of(context);
    scope.profiles.setActive(p.id);
    scope.proxy.selectProfile(p);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NodeListScreen(profileId: p.id),
      ),
    );
  }

  /// Make [p] the active config. If the tunnel is already up, hot-swap to it in
  /// one step (disconnect + reconnect through the new server) so the user does
  /// not have to manually disconnect and reconnect. reconnect() is a no-op when
  /// idle, so selecting a server while disconnected just sets it for next time.
  void _select(BuildContext context, ProxyProfile p) {
    final scope = NovaScope.of(context);
    scope.profiles.setActive(p.id);
    scope.proxy.selectProfile(p);
    final bool switching = scope.proxy.state.isActive ||
        scope.proxy.state == ProxyConnectionState.connecting;
    final s = NovaStrings.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            switching ? s.switchingProfile(p.name) : s.usingProfile(p.name)),
        duration: const Duration(seconds: 1),
      ),
    );
    if (switching) unawaited(scope.proxy.reconnect());
  }

  /// Delete after a confirmation that names the profile, so a mis-tap on a
  /// neighbouring row's menu cannot silently remove the wrong one.
  Future<void> _confirmDelete(
      BuildContext context, ProfilesController profiles, ProxyProfile p) async {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: nova.bgAlt,
        shape: const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
        title: Text(s.serversDelete),
        content: Text(s.serversDeleteConfirm(p.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: nova.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.serversDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (p.isBuiltIn) return;
    profiles.remove(p.id);
  }

  /// Edit a profile's name and URL/link in place.
  Future<void> _editProfile(
      BuildContext context, ProfilesController profiles, ProxyProfile p) async {
    final bool isSub = p.isSubscription;
    final s = NovaStrings.of(context);
    final _ConfigDialogResult? res = await showDialog<_ConfigDialogResult>(
      context: context,
      builder: (BuildContext ctx) => _ConfigDialog(
        titleKey: _ConfigDialogTitle.edit,
        initialName: p.name,
        initialUri: isSub ? (p.subscriptionUrl ?? '') : p.uri,
        uriLabel: isSub ? s.serversSubUrl : s.serversLink,
        uriMaxLines: 2,
      ),
    );
    if (res == null) return;
    final String name = res.name;
    final String url = res.uri;
    final ProxyProfile updated = p.copyWith(
      name: name.isEmpty ? p.name : name,
      subscriptionUrl: isSub ? url : null,
      uri: isSub ? p.uri : url,
      lastLatencyMs: null,
      fastNodes: const <String>[],
    );
    profiles.update(updated);
    // The source may have changed; drop cached nodes so the next resolve refetches.
    clearSubscriptionCache();
    // Saving a list by hand is a decision that its servers may not be the same
    // servers, so every reading taken against the old ones goes with it. The
    // rows come back as "not tested" until the next lightning test.
    unawaited(HealthStore.clear(p.id));
    unawaited(ListFreshness.invalidate(p.id));
    _profileMetadataScheduled.remove(p.id);
    _scheduleProfileMetadata(profiles, updated);
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
        hintText: NovaStrings.of(context).serversSearch,
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
          _FilterTarget(
            selected: selected == null,
            onTap: () => onChanged(null),
            child: NovaPill(
              label: NovaStrings.of(context).serversFilterAll,
              selected: selected == null,
              onTap: () => onChanged(null),
            ),
          ),
          for (final k in kinds) ...<Widget>[
            const SizedBox(width: NovaSpace.sm),
            _FilterTarget(
              selected: selected == k,
              onTap: () => onChanged(k),
              child: NovaPill(
                label: k.label,
                selected: selected == k,
                onTap: () => onChanged(k),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Vertical hit slop and a selected state for a filter pill: the pill is about
/// 30dp tall, under the touch minimum, and its state is otherwise carried by
/// colour alone. Vertical only, so two neighbouring pills' targets never touch.
class _FilterTarget extends StatelessWidget {
  const _FilterTarget({
    required this.child,
    required this.onTap,
    required this.selected,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.profile,
    required this.active,
    required this.onOpen,
    required this.onSelect,
    required this.onDelete,
    required this.onEdit,
    required this.onExtract,
    this.onManage,
  });

  final ProxyProfile profile;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onExtract;

  /// Non-null when this row is backed by a connected VPS, opens its panel.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final s = NovaStrings.of(context);
    final int? latency = profile.lastLatencyMs;
    // A subscription's plan, from the provider's own `subscription-userinfo`
    // header, on the row where the user is choosing between subscriptions.
    // Unlimited plans say so rather than showing a remaining figure that would
    // always read zero.
    final SubInfo? sub =
        profile.isSubscription ? subInfoFor(profile.subscriptionUrl) : null;
    final String? plan = sub == null
        ? null
        : sub.total > 0
            ? '${Fmt.bytes(sub.used)} / ${Fmt.bytes(sub.total)}'
            : '${Fmt.bytes(sub.used)} ${s.serversPlanUnlimited}';
    final String? planLeft = sub != null && sub.total > 0
        ? s.serversPlanLeft.replaceFirst('{n}', Fmt.bytes(sub.remaining))
        : null;

    // The active row is the one thing to find at a glance: a cyan hairline and
    // a faint tint, with the check as the non-colour signal.
    return Material(
      color: active ? nova.cyan.withValues(alpha: 0.07) : nova.surface,
      shape: RoundedRectangleBorder(
        borderRadius: NovaRadii.cardR,
        side: BorderSide(
          color: active ? nova.cyan.withValues(alpha: 0.5) : nova.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Semantics(
          selected: active,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                NovaSpace.md, NovaSpace.md, NovaSpace.xs, NovaSpace.md),
            child: Row(
              children: <Widget>[
                NovaIconChip(
                  icon: profile.isSubscription
                      ? Icons.cloud_sync_rounded
                      : Icons.vpn_key_rounded,
                  color: active ? nova.cyan : nova.indigo,
                ),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(profile.name,
                          maxLines: 1,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: NovaSpace.xs),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: NovaSpace.sm,
                        runSpacing: NovaSpace.xs,
                        children: <Widget>[
                          NovaProtocolBadge(
                            label: profile.kind.label,
                            color: nova.cyan,
                          ),
                          if (profile.isSubscription)
                            Text(s.nodesCount(profile.nodeCount),
                                style: text.labelSmall
                                    ?.copyWith(color: nova.muted)),
                          if (latency != null)
                            _LatencyReadout(latencyMs: latency),
                        ],
                      ),
                      // Byte figures are Latin runs, held LTR so they are not
                      // mirrored when the app is in Farsi.
                      if (plan != null) ...<Widget>[
                        const SizedBox(height: NovaSpace.xs),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: NovaSpace.sm,
                          runSpacing: NovaSpace.xs,
                          children: <Widget>[
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(Icons.data_usage_rounded,
                                    size: 12, color: nova.muted),
                                const SizedBox(width: 4),
                                Directionality(
                                  textDirection: TextDirection.ltr,
                                  child: Text(plan,
                                      style: text.labelSmall
                                          ?.copyWith(color: nova.muted)),
                                ),
                              ],
                            ),
                            if (planLeft != null)
                              Directionality(
                                textDirection: TextDirection.ltr,
                                child: Text(planLeft,
                                    style: text.labelSmall?.copyWith(
                                        color: nova.cyan,
                                        fontWeight: FontWeight.w600)),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: NovaSpace.sm),
                if (active)
                  Icon(Icons.check_circle_rounded, color: nova.cyan, size: 22),
                // A subscription's row opens its node/IP list; hint that with a
                // chevron so it doesn't look like a dead-end.
                if (profile.isSubscription) ...<Widget>[
                  const SizedBox(width: NovaSpace.xs),
                  Icon(Icons.chevron_right_rounded,
                      color: nova.muted, size: 20),
                ],
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded,
                      color: nova.muted, size: 20),
                  tooltip: s.serversActions,
                  onSelected: (String v) {
                    switch (v) {
                      case 'select':
                        onSelect();
                      case 'manage':
                        onManage?.call();
                      case 'extract':
                        onExtract();
                      case 'edit':
                        onEdit();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'select',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline_rounded),
                        title: Text(s.serversSelect),
                      ),
                    ),
                    if (onManage != null)
                      PopupMenuItem<String>(
                        value: 'manage',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.dns_rounded),
                          title: Text(s.vpsManage),
                        ),
                      ),
                    if (profile.isSubscription)
                      PopupMenuItem<String>(
                        value: 'extract',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.list_alt_rounded),
                          title: Text(s.serversExtract),
                        ),
                      ),
                    // Not offered for Nova's own free list. The dialog exists
                    // to show and change a subscription's name and URL, and
                    // neither is the user's to change here: the name is Nova's
                    // and the URL is where the list is published, which is not
                    // something to hand out. A source address that is easy to
                    // read off the screen is easy to block, and the people who
                    // would block it are the reason the list exists.
                    if (!profile.isBuiltIn)
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.edit_outlined),
                          title: Text(s.serversEdit),
                        ),
                      ),
                    // Nova's own free servers cannot be deleted. They are the
                    // one entry a person who has nothing else can always fall
                    // back to, including the person who deleted everything by
                    // accident, so removing them is not an option Nova offers.
                    if (!profile.isBuiltIn)
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline_rounded,
                              color: nova.danger),
                          title: Text(s.serversDelete,
                              style: TextStyle(color: nova.danger)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Latency + signal bars, folded into the row's meta line so the trailing
/// edge only carries the state (check, chevron, menu). Tabular figures keep
/// the number steady as it refreshes.
class _LatencyReadout extends StatelessWidget {
  const _LatencyReadout({required this.latencyMs});
  final int latencyMs;

  @override
  Widget build(BuildContext context) {
    final Color c = NovaSemantics.ping(latencyMs);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NovaSignalBars(latencyMs: latencyMs),
        const SizedBox(width: 6),
        Flexible(
          child: Text('$latencyMs ms',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                  )),
        ),
      ],
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
    final s = NovaStrings.of(context);

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
            child:
                const Icon(Icons.bolt_rounded, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 16),
        Text(s.serversEmpty,
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(s.serversEmptySub,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: nova.muted)),
        const SizedBox(height: 20),
        _EmptyAction(
          icon: Icons.cloud_upload_rounded,
          title: s.serversDeploy,
          subtitle: s.serversDeploySub,
          highlighted: true,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeployScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _EmptyAction(
          icon: Icons.login_rounded,
          title: s.serversSignIn,
          subtitle: s.serversSignInSub,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CloudflareScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _EmptyAction(
          icon: Icons.dns_rounded,
          title: s.serversConnectVps,
          subtitle: s.serversConnectVpsSub,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ConnectVpsScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _EmptyAction(
          icon: Icons.add_rounded,
          title: s.serversAddConfig,
          subtitle: s.serversAddConfigSub,
          onTap: () => showAddConfigSheet(context),
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
Future<void> showAddServerDialog(BuildContext context,
    {String? prefill}) async {
  final NovaScope scope = NovaScope.of(context);
  final profiles = scope.profiles;
  final s = NovaStrings.of(context);

  // A `nova-relay://` link is a relay setup, not a proxy config: apply it to the
  // relay (and tunnel) and stop, so it never becomes a bogus server entry.
  final RelayLinkData? relayLink = RelayLinkData.decode(prefill ?? '');
  if (relayLink != null) {
    await scope.relay.applyLink(relayLink);
    await scope.tunnel.applyLink(relayLink);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.relayImportedOk)),
      );
    }
    return;
  }

  final ProxyKind detected =
      _detectKind(prefill ?? '') ?? ProxyKind.subscription;

  final _ConfigDialogResult? res = await showDialog<_ConfigDialogResult>(
    context: context,
    builder: (BuildContext ctx) => _ConfigDialog(
      titleKey: _ConfigDialogTitle.add,
      initialUri: prefill ?? '',
      initialKind: detected,
      showKindPills: true,
      uriHint: s.serversUriHint,
      // An AmneziaWG `.conf` is multi-line, so give it room instead of a
      // one-line field that would flatten the pasted text.
      uriMaxLines: detected == ProxyKind.awg ? 8 : 1,
    ),
  );

  if (res != null && res.uri.isNotEmpty) {
    final String uri = res.uri;
    // Trust what was pasted over the selected pill: a link's scheme tells us
    // exactly what it is, so an https://…/sub URL or a vless:// link always
    // lands in the right field instead of failing later as an invalid link.
    final ProxyKind resolved = _detectKind(uri) ?? res.kind;
    final bool isSub = resolved == ProxyKind.subscription;
    final ProxyProfile profile = ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: res.name.isEmpty
          ? 'Server ${profiles.profiles.length + 1}'
          : res.name,
      kind: resolved,
      uri: isSub ? '' : uri,
      subscriptionUrl: isSub ? uri : null,
      updatedAt: DateTime.now(),
    );
    profiles.add(profile);
    // Resolve metadata and a live ping right away. Fire-and-forget: a slow or
    // failed endpoint must not block adding the config.
    _scheduleProfileMetadata(profiles, profile);
  }
}

void _scheduleProfileMetadata(
    ProfilesController profiles, ProxyProfile profile) {
  if (!_profileMetadataScheduled.add(profile.id)) return;
  unawaited(_resolveProfileMetadata(profiles, profile));
}

/// Resolves the real node count for the Servers/Home cards.
///
/// It used to probe a sample of exits here as well, to put a latency on the
/// card. That was a test the user never asked for, running every time this page
/// opened, on a probe that could not judge most protocols; it is gone. A card's
/// latency now comes from a lightning test, and stays blank until there is one.
Future<void> _resolveProfileMetadata(
    ProfilesController profiles, ProxyProfile snapshot) async {
  try {
    final List<ProxyNode> resolved = await resolveProfileNodes(snapshot);
    if (resolved.isEmpty) return;
    // Deduped, so the card counts servers the user can choose between rather
    // than lines in the subscription. Nova's own free list carries the same
    // server three times over.
    final Set<String> seen = <String>{};
    final List<ProxyNode> nodes = <ProxyNode>[
      for (final ProxyNode n in resolved)
        if (seen.add(proxyNodeKey(n))) n,
    ];

    ProxyProfile? current;
    for (final ProxyProfile candidate in profiles.profiles) {
      if (candidate.id == snapshot.id) {
        current = candidate;
        break;
      }
    }
    if (current == null ||
        current.uri != snapshot.uri ||
        current.subscriptionUrl != snapshot.subscriptionUrl) {
      return;
    }

    // The Telegram proxy and the operator's SNI-block default come out of the
    // same parse (see lastTelegramProxy / lastSniBlockBypass), so they are
    // picked up whenever the node count is.
    //
    // The bypass is a DEFAULT, not a lock. It is applied only while the user has
    // not decided for themselves: once they have touched the switch, their
    // choice stands and a refresh leaves it alone. Without that, an operator who
    // turns it on would silently re-enable it every time the list refreshed, on
    // top of the user having turned it off.
    final bool applyBypass = lastSniBlockBypass && !current.hardenTlsUserSet;
    profiles.update(current.copyWith(
      nodeCount: nodes.length,
      telegramProxy: lastTelegramProxy?.url,
      telegramProxyWeb: lastTelegramProxy?.webUrl,
      hardenTls: applyBypass ? true : null,
    ));
  } catch (_) {
    // Keep the existing metadata; a later app launch or node-list refresh will
    // try again.
  }
}

enum _ConfigDialogTitle { add, edit }

class _ConfigDialogResult {
  const _ConfigDialogResult(this.name, this.uri, this.kind);
  final String name;
  final String uri;
  final ProxyKind kind;
}

/// Name + URI (+ optional protocol pills) dialog shared by the add and edit
/// flows. It is a StatefulWidget so it OWNS its [TextEditingController]s and
/// disposes them in [State.dispose] — i.e. only after the dialog route is fully
/// gone. The previous version created the controllers outside `showDialog` and
/// disposed them the moment the future returned, so a rebuild during the exit
/// animation or a back-button dismiss used a disposed controller and crashed
/// (and no config got saved). Owning them here fixes that and the matching leak
/// in the edit dialog.
class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog({
    required this.titleKey,
    this.initialName = '',
    this.initialUri = '',
    this.initialKind = ProxyKind.subscription,
    this.showKindPills = false,
    this.uriHint,
    this.uriLabel,
    this.uriMaxLines = 1,
  });

  final _ConfigDialogTitle titleKey;
  final String initialName;
  final String initialUri;
  final ProxyKind initialKind;
  final bool showKindPills;
  final String? uriHint;
  final String? uriLabel;
  final int uriMaxLines;

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _uriCtrl =
      TextEditingController(text: widget.initialUri);
  late ProxyKind _kind = widget.initialKind;

  /// AmneziaWG configs arrive as a `.conf` file. Let the user pick one and drop
  /// its text straight into the URI field, where the normal Save path parses it
  /// (looksLikeConf -> ProxyKind.awg). The name is filled from the file when the
  /// user left it blank. A cancelled or unreadable pick leaves the field as-is.
  Future<void> _pickConfFile() async {
    final NovaStrings s = NovaStrings.of(context);
    try {
      // Ask for text / .conf only. Android's picker does not enforce an
      // extension filter, so the content is checked below regardless.
      final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[
        const XTypeGroup(
          label: 'WireGuard / AmneziaWG config',
          extensions: <String>['conf', 'txt'],
          mimeTypes: <String>['text/plain', 'application/octet-stream'],
          uniformTypeIdentifiers: <String>['public.plain-text', 'public.data'],
        ),
      ]);
      if (file == null) return;
      // A .conf is a few hundred bytes. Anything big is the wrong file (a
      // photo, an APK); reading it whole into a text field used to take the
      // app down, and decoding a binary as UTF-8 throws.
      final int size = await file.length();
      if (size > 64 * 1024) {
        _notConf(s);
        return;
      }
      final String text = (await file.readAsString()).trim();
      if (!mounted) return;
      if (text.isEmpty || !AwgConfig.looksLikeConf(text)) {
        _notConf(s);
        return;
      }
      // Parse it now, so a conf missing its Endpoint or keys is refused here
      // with a reason instead of becoming a profile that can never connect.
      try {
        AwgConfig.parseConf(text);
      } on FormatException catch (e) {
        _notConf(s, detail: e.message);
        return;
      }
      setState(() {
        _uriCtrl.text = text;
        _kind = ProxyKind.awg;
        if (_nameCtrl.text.trim().isEmpty && file.name.isNotEmpty) {
          _nameCtrl.text =
              file.name.replaceAll(RegExp(r'\.conf$', caseSensitive: false), '');
        }
      });
    } on FormatException {
      // Not UTF-8 text: a binary file was picked.
      if (mounted) _notConf(s);
    } catch (_) {
      // Best-effort import; any other failure leaves the dialog untouched.
    }
  }

  /// Shown under the field; a snackbar would land behind the dialog's scrim.
  String? _fieldError;

  void _notConf(NovaStrings s, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _fieldError = detail == null ? s.awgNotConf : '${s.awgNotConf} ($detail)';
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _uriCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final String title =
        widget.titleKey == _ConfigDialogTitle.add ? s.add : s.serversEdit;
    return AlertDialog(
      backgroundColor: context.nova.bgAlt,
      shape: const RoundedRectangleBorder(borderRadius: NovaRadii.cardR),
      title: Text(title, style: Theme.of(context).textTheme.titleLarge),
      // Scrollable: with the AmneziaWG field at eight lines and the keyboard
      // up, the fixed layout let the action row paint over the pills.
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
                hintText: s.serversName, labelText: s.serversName),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _uriCtrl,
            // An AmneziaWG conf is multi-line. The field must be multi-line
            // whenever that pill is selected, not only when the dialog was
            // opened with a conf: a single-line field on Android drops the
            // newlines of a pasted conf, which then cannot parse.
            maxLines: _kind == ProxyKind.awg ? 8 : widget.uriMaxLines,
            keyboardType: _kind == ProxyKind.awg
                ? TextInputType.multiline
                : TextInputType.url,
            onChanged: (_) {
              if (_fieldError != null) setState(() => _fieldError = null);
            },
            decoration: InputDecoration(
              hintText: widget.uriHint,
              labelText: widget.uriLabel,
              errorText: _fieldError,
              errorMaxLines: 4,
            ),
          ),
          if (widget.showKindPills) ...<Widget>[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final ProxyKind k in ProxyKind.values)
                    NovaPill(
                      label: k.label,
                      selected: _kind == k,
                      onTap: () => setState(() => _kind = k),
                    ),
                ],
              ),
            ),
            if (_kind == ProxyKind.awg) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _pickConfFile,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: Text(s.awgImportConf),
                ),
              ),
            ],
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        TextButton(
          onPressed: () {
            final String uri = _uriCtrl.text.trim();
            // An AmneziaWG entry must be a parseable conf. Saving anything
            // else made a profile that could never connect (and a big enough
            // paste could take the app down later).
            final bool awg = _kind == ProxyKind.awg ||
                (AwgConfig.looksLikeConf(uri) && _detectKind(uri) == ProxyKind.awg);
            if (awg && uri.isNotEmpty) {
              if (!AwgConfig.looksLikeConf(uri)) {
                _notConf(s);
                return;
              }
              try {
                AwgConfig.parseConf(uri);
              } on FormatException catch (e) {
                _notConf(s, detail: e.message);
                return;
              }
            }
            Navigator.pop(
              context,
              _ConfigDialogResult(_nameCtrl.text.trim(), uri, _kind),
            );
          },
          child: Text(s.save),
        ),
      ],
    );
  }
}

/// Infers the profile kind from the scheme of what was pasted, or null when it
/// is not recognisable (so the manually selected pill is used as the fallback).
ProxyKind? _detectKind(String raw) {
  final String s = raw.trim();
  final String l = s.toLowerCase();
  if (l.startsWith('socks://') || l.startsWith('socks5://')) {
    return ProxyKind.socks;
  }
  if (l.startsWith('http://') || l.startsWith('https://')) {
    // An http(s) link with `user:pass@` is a proxy; without it, a subscription.
    return s.contains('@') ? ProxyKind.http : ProxyKind.subscription;
  }
  if (l.startsWith('vless://')) return ProxyKind.vless;
  if (l.startsWith('trojan://')) return ProxyKind.trojan;
  if (l.startsWith('ss://')) return ProxyKind.shadowsocks;
  if (l.startsWith('hysteria2://') || l.startsWith('hy2://')) {
    return ProxyKind.hysteria2;
  }
  if (l.startsWith('vmess://')) return ProxyKind.vmess;
  if (l.startsWith('tuic://')) return ProxyKind.tuic;
  if (s.startsWith('{')) return ProxyKind.singboxConfig;
  // An AmneziaWG / WireGuard `.conf` (pasted text or QR), or an awg:// link.
  if (l.startsWith('awg://') ||
      l.startsWith('wireguard://') ||
      AwgConfig.looksLikeConf(s)) {
    return ProxyKind.awg;
  }
  return null;
}

/// The "Add config" entry point: an options sheet (Scan QR / Paste / Enter
/// manually) that all funnel into [showAddServerDialog] so naming and kind
/// detection stay shared. QR scanning is only offered where a camera exists.
Future<void> showAddConfigSheet(BuildContext context) async {
  final nova = context.nova;
  final s = NovaStrings.of(context);
  final bool canScan = Platform.isIOS || Platform.isAndroid || Platform.isMacOS;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: nova.bgAlt,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext sheetCtx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: nova.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            // "Connect your VPS" is not here. The + sheet is the path people
            // take many times a week to add a link or a file; running your own
            // server is a once-ever decision and it lives on the empty-servers
            // screen, where someone with nothing yet actually meets it.
            if (canScan)
              _AddOption(
                icon: Icons.qr_code_scanner_rounded,
                color: nova.cyan,
                title: s.serversScanQr,
                subtitle: s.serversScanQrSub,
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final String? code = await Navigator.of(context).push<String>(
                    MaterialPageRoute<String>(
                        builder: (_) => const QrScanScreen()),
                  );
                  if (code != null &&
                      code.trim().isNotEmpty &&
                      context.mounted) {
                    await showAddServerDialog(context, prefill: code.trim());
                  }
                },
              ),
            _AddOption(
              icon: Icons.content_paste_rounded,
              color: nova.violet,
              title: s.serversPaste,
              subtitle: s.serversPasteSub,
              onTap: () async {
                Navigator.pop(sheetCtx);
                final ClipboardData? data =
                    await Clipboard.getData(Clipboard.kTextPlain);
                final String text = (data?.text ?? '').trim();
                if (!context.mounted) return;
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(s.serversClipboardEmpty)),
                  );
                  return;
                }
                await showAddServerDialog(context, prefill: text);
              },
            ),
            _AddOption(
              icon: Icons.edit_rounded,
              color: nova.indigo,
              title: s.serversManual,
              subtitle: s.serversManualSub,
              onTap: () async {
                Navigator.pop(sheetCtx);
                await showAddServerDialog(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class _AddOption extends StatelessWidget {
  const _AddOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return ListTile(
      leading: NovaIconChip(icon: icon, color: color, size: 38, radius: 11),
      title: Text(title,
          style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
      subtitle:
          Text(subtitle, style: text.bodySmall?.copyWith(color: nova.muted)),
      onTap: onTap,
    );
  }
}

/// Full-screen camera QR scanner; pops the first decoded string back to the
/// caller, which feeds it into the add-config dialog.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final Barcode b in capture.barcodes) {
      final String? v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(NovaStrings.of(context).serversScanQr),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: MobileScanner(controller: _controller, onDetect: _onDetect),
    );
  }
}
