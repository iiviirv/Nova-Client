import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/models/proxy_profile.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_components.dart';
import '../../widgets/nova_pill.dart';
import '../../core/proxy/subscription.dart';
import '../../widgets/nova_scope.dart';
import '../profiles/profiles_controller.dart';
import '../cloudflare/cloudflare_screen.dart';
import '../cloudflare/deploy_screen.dart';
import 'node_list_screen.dart';

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
                onOpen: () => _open(context, p),
                onSelect: () => _select(context, p),
                onExtract: () => _openNodes(context, p),
                onEdit: () => _editProfile(context, profiles, p),
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

  /// Make [p] the active config used for the next connect.
  void _select(BuildContext context, ProxyProfile p) {
    final scope = NovaScope.of(context);
    scope.profiles.setActive(p.id);
    scope.proxy.selectProfile(p);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Using ${p.name}'), duration: const Duration(seconds: 1)),
    );
  }

  /// Edit a profile's name and URL/link in place.
  Future<void> _editProfile(
      BuildContext context, ProfilesController profiles, ProxyProfile p) async {
    final TextEditingController nameC = TextEditingController(text: p.name);
    final bool isSub = p.isSubscription;
    final TextEditingController urlC = TextEditingController(
        text: isSub ? (p.subscriptionUrl ?? '') : p.uri);
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Edit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlC,
              maxLines: 2,
              decoration: InputDecoration(
                  labelText: isSub ? 'Subscription URL' : 'Link'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final String name = nameC.text.trim();
    final String url = urlC.text.trim();
    profiles.update(p.copyWith(
      name: name.isEmpty ? p.name : name,
      subscriptionUrl: isSub ? url : null,
      uri: isSub ? p.uri : url,
    ));
    // The source may have changed; drop cached nodes so the next resolve refetches.
    clearSubscriptionCache();
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
    required this.onOpen,
    required this.onSelect,
    required this.onDelete,
    required this.onEdit,
    required this.onExtract,
  });

  final ProxyProfile profile;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onExtract;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
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
              Icon(Icons.check_circle_rounded, color: nova.cyan, size: 22),
            // A subscription's row opens its node/IP list; hint that with a
            // chevron so it doesn't look like a dead-end.
            if (profile.isSubscription)
              Icon(Icons.chevron_right_rounded, color: nova.muted, size: 20),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: nova.muted, size: 20),
              tooltip: 'Actions',
              onSelected: (String v) {
                switch (v) {
                  case 'select':
                    onSelect();
                  case 'extract':
                    onExtract();
                  case 'edit':
                    onEdit();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'select',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.check_circle_outline_rounded),
                    title: Text('Select'),
                  ),
                ),
                if (profile.isSubscription)
                  const PopupMenuItem<String>(
                    value: 'extract',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.list_alt_rounded),
                      title: Text('Extract configs'),
                    ),
                  ),
                const PopupMenuItem<String>(
                  value: 'edit',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Edit'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline_rounded, color: nova.danger),
                    title: Text('Delete', style: TextStyle(color: nova.danger)),
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
  final profiles = NovaScope.of(context).profiles;
  final s = NovaStrings.of(context);
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController uriCtrl =
      TextEditingController(text: prefill ?? '');
  ProxyKind kind = _detectKind(prefill ?? '') ?? ProxyKind.subscription;

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
    // Trust what was pasted over the selected pill: a link's scheme tells us
    // exactly what it is, so an https://…/sub URL or a vless:// link always
    // lands in the right field instead of failing later as an invalid link.
    final ProxyKind resolved = _detectKind(uri) ?? kind;
    final bool isSub = resolved == ProxyKind.subscription;
    profiles.add(ProxyProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: nameCtrl.text.trim().isEmpty
          ? 'Server ${profiles.profiles.length + 1}'
          : nameCtrl.text.trim(),
      kind: resolved,
      uri: isSub ? '' : uri,
      subscriptionUrl: isSub ? uri : null,
      updatedAt: DateTime.now(),
    ));
  }
  nameCtrl.dispose();
  uriCtrl.dispose();
}

/// Infers the profile kind from the scheme of what was pasted, or null when it
/// is not recognisable (so the manually selected pill is used as the fallback).
ProxyKind? _detectKind(String raw) {
  final String s = raw.trim();
  final String l = s.toLowerCase();
  if (l.startsWith('http://') || l.startsWith('https://')) {
    return ProxyKind.subscription;
  }
  if (l.startsWith('vless://')) return ProxyKind.vless;
  if (l.startsWith('trojan://')) return ProxyKind.trojan;
  if (l.startsWith('ss://')) return ProxyKind.shadowsocks;
  if (s.startsWith('{')) return ProxyKind.singboxConfig;
  return null;
}

/// The "Add config" entry point: an options sheet (Scan QR / Paste / Enter
/// manually) that all funnel into [showAddServerDialog] so naming and kind
/// detection stay shared. QR scanning is only offered where a camera exists.
Future<void> showAddConfigSheet(BuildContext context) async {
  final nova = context.nova;
  final bool canScan =
      Platform.isIOS || Platform.isAndroid || Platform.isMacOS;
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
            if (canScan)
              _AddOption(
                icon: Icons.qr_code_scanner_rounded,
                color: nova.cyan,
                title: 'Scan QR code',
                subtitle: 'Point the camera at a config QR',
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final String? code =
                      await Navigator.of(context).push<String>(
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
              title: 'Paste from clipboard',
              subtitle: 'Import a link or subscription you copied',
              onTap: () async {
                Navigator.pop(sheetCtx);
                final ClipboardData? data =
                    await Clipboard.getData(Clipboard.kTextPlain);
                final String text = (data?.text ?? '').trim();
                if (!context.mounted) return;
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Clipboard is empty')),
                  );
                  return;
                }
                await showAddServerDialog(context, prefill: text);
              },
            ),
            _AddOption(
              icon: Icons.edit_rounded,
              color: nova.indigo,
              title: 'Enter manually',
              subtitle: 'Paste or type a link or subscription URL',
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
      subtitle: Text(subtitle,
          style: text.bodySmall?.copyWith(color: nova.muted)),
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
        title: const Text('Scan QR code'),
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
