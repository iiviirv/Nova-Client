import 'package:flutter/material.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_scope.dart';
import 'vps_controller.dart';
import 'vps_manual_screen.dart';
import 'vps_ssh_screen.dart';

/// The "Connect your VPS" entry screen: two large tappable cards that branch
/// into the manual (paste-and-connect) or SSH (install-it-for-me) flows. The
/// SSH card is the recommended path and gets the highlighted treatment. Any
/// stale controller state from a previous run is cleared on entry so the flow
/// always starts fresh.
class ConnectVpsScreen extends StatefulWidget {
  const ConnectVpsScreen({super.key});

  @override
  State<ConnectVpsScreen> createState() => _ConnectVpsScreenState();
}

class _ConnectVpsScreenState extends State<ConnectVpsScreen> {
  List<VpsPanel> _panels = <VpsPanel>[];
  String? _connectingId; // host id of the panel currently connecting

  @override
  void initState() {
    super.initState();
    // Clear any half-finished state from a prior attempt after the first frame,
    // so returning to this screen never shows a stale success or error, then
    // load the saved panels so a connected VPS stays manageable anytime.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NovaScope.of(context).vps.reset();
      _loadPanels();
    });
  }

  Future<void> _loadPanels() async {
    final List<VpsPanel> panels = await NovaScope.of(context).vps.loadPanels();
    if (!mounted) return;
    setState(() => _panels = panels);
  }

  Future<void> _removePanel(VpsPanel panel) async {
    final s = NovaStrings.of(context);
    final VpsController vps = NovaScope.of(context).vps;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(s.vpsRemovePanel),
        content: Text(s.vpsRemovePanelConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.vpsCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.vpsRemovePanel,
                style: TextStyle(color: ctx.nova.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await vps.removePanel(panel.id);
    if (!mounted) return;
    await _loadPanels();
  }

  Future<void> _connectPanel(VpsPanel panel) async {
    final s = NovaStrings.of(context);
    final VpsController vps = NovaScope.of(context).vps;
    setState(() => _connectingId = panel.id);
    final bool ok = await vps.connectSavedPanel(panel);
    if (!mounted) return;
    setState(() => _connectingId = null);
    if (ok) {
      // The node is in the server list and the tunnel is connecting; drop the
      // user back to the app so they see it turn on.
      Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(vps.error ?? s.vpsFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    return Scaffold(
      appBar: AppBar(title: Text(s.vpsTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            children: <Widget>[
              Text(
                s.vpsSubtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: nova.muted),
              ),
              const SizedBox(height: NovaSpace.xl),
              if (_panels.isNotEmpty) ...<Widget>[
                Text(
                  s.vpsYourPanels,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: NovaSpace.md),
                for (final VpsPanel p in _panels) ...<Widget>[
                  _SavedPanelCard(
                    panel: p,
                    busy: _connectingId == p.id,
                    onConnect: () => _connectPanel(p),
                    onManage: () =>
                        NovaScope.of(context).vps.openAdminFor(context, p),
                    onRemove: () => _removePanel(p),
                  ),
                  const SizedBox(height: NovaSpace.md),
                ],
                const SizedBox(height: NovaSpace.sm),
              ],
              _VpsEntryCard(
                icon: Icons.terminal_rounded,
                title: s.vpsManualCard,
                subtitle: s.vpsManualCardSub,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const VpsManualScreen()),
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              _VpsEntryCard(
                icon: Icons.rocket_launch_rounded,
                title: s.vpsSshCard,
                subtitle: s.vpsSshCardSub,
                highlighted: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VpsSshScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A saved-VPS row: a gradient node chip, the panel name + base URL, a Manage
/// button that reopens the admin panel, and an overflow menu to remove it.
class _SavedPanelCard extends StatelessWidget {
  const _SavedPanelCard({
    required this.panel,
    required this.onConnect,
    required this.onManage,
    required this.onRemove,
    this.busy = false,
  });

  final VpsPanel panel;
  final VoidCallback onConnect;
  final VoidCallback onManage;
  final VoidCallback onRemove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      padding: const EdgeInsets.all(NovaSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: NovaGradients.logo,
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    const Icon(Icons.dns_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: NovaSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      panel.name,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      panel.baseUrl,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: nova.muted),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: s.vpsRemovePanel,
                icon: Icon(Icons.more_vert_rounded, color: nova.muted),
                onSelected: (String v) {
                  if (v == 'remove') onRemove();
                },
                itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'remove',
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.delete_outline_rounded,
                            size: 18, color: nova.danger),
                        const SizedBox(width: NovaSpace.sm),
                        Text(s.vpsRemovePanel),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.md),
          Row(
            children: <Widget>[
              Expanded(
                child: NovaButton(
                  label: s.vpsConnectNow,
                  icon: Icons.bolt_rounded,
                  loading: busy,
                  onPressed: busy ? null : onConnect,
                ),
              ),
              const SizedBox(width: NovaSpace.sm),
              Expanded(
                child: NovaButton(
                  label: s.vpsManage,
                  variant: NovaButtonVariant.secondary,
                  onPressed: busy ? null : onManage,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One large entry card, mirroring the Servers empty-state `_EmptyAction`: a
/// gradient icon chip, a title/subtitle stack, and a trailing chevron. The
/// highlighted variant tints the surface and border with the accent to read as
/// the recommended choice.
class _VpsEntryCard extends StatelessWidget {
  const _VpsEntryCard({
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
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: NovaGradients.logo,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: NovaSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
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
