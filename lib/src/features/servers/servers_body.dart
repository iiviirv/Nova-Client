import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/singbox/awg_config.dart';
import '../../core/proxy/singbox/node_probe.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../relay/relay_link.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_pill.dart';
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
        final List<ProxyProfile> shown = all.where((p) {
          if (_filter != null && p.kind != _filter) return false;
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
                onOpen: () => _open(context, p),
                onSelect: () => _select(context, p),
                onExtract: () => _openNodes(context, p),
                onEdit: () => _editProfile(context, profiles, p),
                onDelete: () => profiles.remove(p.id),
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

    return GestureDetector(
      onTap: onOpen,
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
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: <Widget>[
                      NovaProtocolBadge(
                        label: profile.kind.label,
                        color: nova.cyan,
                      ),
                      if (profile.isSubscription)
                        Text('${profile.nodeCount} nodes',
                            style:
                                text.labelSmall?.copyWith(color: nova.muted)),
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
              Icon(Icons.check_circle_rounded, color: nova.cyan, size: 22),
            // A subscription's row opens its node/IP list; hint that with a
            // chevron so it doesn't look like a dead-end.
            if (profile.isSubscription)
              Icon(Icons.chevron_right_rounded, color: nova.muted, size: 20),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: nova.muted, size: 20),
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
                PopupMenuItem<String>(
                  value: 'edit',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(s.serversEdit),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading:
                        Icon(Icons.delete_outline_rounded, color: nova.danger),
                    title: Text(s.serversDelete,
                        style: TextStyle(color: nova.danger)),
                  ),
                ),
              ],
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

/// Resolves the real node count and measures a representative live latency for
/// the Servers/Home cards. A bounded sample keeps large subscriptions cheap;
/// opening the node list still measures up to 80 exits in detail.
Future<void> _resolveProfileMetadata(
    ProfilesController profiles, ProxyProfile snapshot) async {
  try {
    final List<ProxyNode> nodes = await resolveProfileNodes(snapshot);
    if (nodes.isEmpty) return;

    final measured = await Future.wait(
      nodes.take(12).map((ProxyNode node) async => (
            node: node,
            probe: await probeNode(
              node,
              timeout: const Duration(seconds: 5),
            ),
          )),
    );
    // Only nodes a probe could actually prove are worth putting on a card or
    // seeding auto-select with; a TCP connect that proved nothing used to land
    // here as a latency.
    final reachable = measured.where((result) => result.probe.ok).toList()
      ..sort((a, b) => a.probe.sortKey.compareTo(b.probe.sortKey));

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

    profiles.update(current.copyWith(
      nodeCount: nodes.length,
      lastLatencyMs: reachable.isEmpty
          ? current.lastLatencyMs
          : reachable.first.probe.latencyMs,
      fastNodes: reachable.isEmpty
          ? current.fastNodes
          : reachable
              .take(24)
              .map((result) => proxyNodeKey(result.node))
              .toList(),
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
            maxLines: widget.uriMaxLines,
            decoration: InputDecoration(
              hintText: widget.uriHint,
              labelText: widget.uriLabel,
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
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            _ConfigDialogResult(
                _nameCtrl.text.trim(), _uriCtrl.text.trim(), _kind),
          ),
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
            _AddOption(
              icon: Icons.dns_rounded,
              color: nova.cyan,
              title: s.serversConnectVps,
              subtitle: s.serversConnectVpsSub,
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ConnectVpsScreen(),
                  ),
                );
              },
            ),
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
