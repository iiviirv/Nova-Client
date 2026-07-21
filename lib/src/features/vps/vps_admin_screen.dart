import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_segmented_tabs.dart';
import '../cloudflare/nova_panel.dart';
import 'package:http/http.dart' as http;
import 'insecure_http.dart';
import 'vps_controller.dart';

/// The full admin panel for a connected VPS node. Fuller sibling of
/// [PanelAdminScreen]: it adds first-class user management (add/edit/enable/
/// delete, per-user quota + expiry, live usage) on top of the same editable
/// config, network/routing settings, and custom clean-IP list. Opened once the
/// worker URL + admin password are already known.
class VpsAdminScreen extends StatefulWidget {
  const VpsAdminScreen({
    super.key,
    required this.workerUrl,
    required this.password,
    required this.title,
    this.allowInsecure = false,
    this.relayClient,
  });

  final String workerUrl;
  final String password;
  final String title;

  /// True for a no-domain VPS agent that serves a self-signed certificate.
  final bool allowInsecure;

  /// When set, admin calls go through the Google relay instead of hitting the
  /// panel directly (so a blocked panel domain is still manageable).
  final http.Client? relayClient;

  @override
  State<VpsAdminScreen> createState() => _VpsAdminScreenState();
}

class _VpsAdminScreenState extends State<VpsAdminScreen> {
  late final NovaPanel _panel = NovaPanel(
    client: widget.relayClient ?? (widget.allowInsecure ? buildInsecureClient() : null),
  );
  PanelSession? _session;

  List<Map<String, dynamic>> _users = <Map<String, dynamic>>[];
  // Live node dashboard (system/traffic/geo). Best-effort: worker panels don't
  // serve it, so it simply stays empty there and the Overview tab shows dashes.
  Map<String, dynamic> _dashboard = <String, dynamic>{};
  // Per-user online device counts (`{userId: count}`). Best-effort.
  Map<String, int> _online = <String, int>{};
  // WARP account + toggles from /admin/warp. Best-effort.
  Map<String, dynamic> _warp = <String, dynamic>{};
  bool _warpBusy = false;
  bool _maintBusy = false;
  bool _tgBusy = false;
  // The node's subscription URL, for the three copyable formats in Info.
  String _subUrl = '';
  // Data-driven standalone Xray inbounds (Reality/Vision, gRPC, XHTTP, WS,
  // Shadowsocks-2022, Trojan+Reality). Best-effort: worker panels don't serve
  // this, so the list simply stays empty there.
  List<Map<String, dynamic>> _inbounds = <Map<String, dynamic>>[];
  bool _savingInbounds = false;
  Map<String, int> _usage = <String, int>{};
  Map<String, dynamic> _config = <String, dynamic>{};
  Map<String, dynamic> _net = <String, dynamic>{};
  // Which protocols the node offers. VLESS is always on; VMess/Trojan are opt-in
  // and toggling either triggers an xray reload server-side.
  Map<String, dynamic> _protocols = <String, dynamic>{'vless': true};
  bool _savingProtocols = false;
  Whoami? _whoami;
  // Kept from the network-settings document so the per-user share sheet can
  // build a working vless link without re-reading the panel.
  String _host = '';
  String _wsPath = '';
  late final TextEditingController _ipsCtrl = TextEditingController();

  // Domain & TLS. Status is best-effort (worker panels don't serve it).
  Map<String, dynamic> _domain = <String, dynamic>{};
  late final TextEditingController _domainCtrl = TextEditingController();
  late final TextEditingController _certCtrl = TextEditingController();
  late final TextEditingController _keyCtrl = TextEditingController();
  late final TextEditingController _emailCtrl = TextEditingController();
  String _domainMethod = 'letsencrypt'; // 'letsencrypt' | 'origin'
  bool _provisioning = false;

  int _tab = 0;
  bool _loading = true;
  String? _error;
  bool _savingUsers = false;
  String _saving = ''; // '', 'config', 'net', 'ips'

  // Editable config flags (HOST/UUID are read-only server-side).
  static const List<(String, String)> _configToggles = <(String, String)>[
    ('tlsFragment', 'TLS fragment'),
    ('skipCertVerify', 'Skip cert verify'),
    ('enable0RTT', '0-RTT'),
    ('randomPath', 'Random path'),
  ];

  static const List<String> _dohProviders = <String>[
    'cloudflare',
    'google',
    'quad9',
    'adguard',
  ];
  static const List<String> _antiSanctionProviders = <String>[
    'shecan',
    'electro',
    'cloudflare',
    'google',
    'quad9',
    'custom',
  ];
  static const List<String> _warpModes = <String>['warp', 'wow', 'chain'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ipsCtrl.dispose();
    _domainCtrl.dispose();
    _certCtrl.dispose();
    _keyCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PanelSession session =
          await _panel.login(widget.workerUrl, widget.password);
      // Kick off the independent reads together, then await each.
      final Future<List<Map<String, dynamic>>> fUsers = _panel.getUsers(session);
      final Future<Map<String, int>> fUsage = _panel.usageByUser(session);
      final Future<Map<String, dynamic>> fConfig = _panel.getConfig(session);
      final Future<Map<String, dynamic>> fNet = _panel.getNetworkSettings(session);
      final List<Map<String, dynamic>> users = await fUsers;
      final Map<String, int> usage = await fUsage;
      final Map<String, dynamic> config = await fConfig;
      final Map<String, dynamic> net = await fNet;
      Whoami? who;
      try {
        who = await _panel.whoami(session);
      } catch (_) {/* a VPS often returns blanks; best-effort */}
      String ips = '';
      try {
        ips = await _panel.getIPs(session);
      } catch (_) {/* ADD.txt may be empty/absent */}
      Map<String, dynamic> domain = <String, dynamic>{};
      try {
        domain = await _panel.getDomainStatus(session);
      } catch (_) {/* worker panels don't serve a domain status */}
      List<Map<String, dynamic>> inbounds = <Map<String, dynamic>>[];
      try {
        inbounds = await _panel.getInbounds(session);
      } catch (_) {/* worker panels don't serve inbounds */}
      Map<String, dynamic> dashboard = <String, dynamic>{};
      try {
        dashboard = await _panel.getDashboard(session);
      } catch (_) {/* worker panels don't serve a dashboard */}
      Map<String, int> online = <String, int>{};
      try {
        online = _parseOnline(await _panel.getOnline(session));
      } catch (_) {/* best-effort */}
      Map<String, dynamic> warp = <String, dynamic>{};
      try {
        warp = await _panel.getWarp(session);
      } catch (_) {/* best-effort */}
      String subUrl = '';
      try {
        subUrl = (await _panel.importableSubscription(session)).trim();
      } catch (_) {/* best-effort */}
      String host = (net['host'] as String?)?.trim() ?? '';
      if (host.isEmpty) host = Uri.tryParse(session.workerUrl)?.host ?? '';
      final String wsPath = (net['wsPath'] as String?)?.trim() ?? '';
      final Map<String, dynamic> protocols =
          (net['protocols'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ??
              <String, dynamic>{'vless': true};
      if (!mounted) return;
      setState(() {
        _session = session;
        _users = users;
        _inbounds = inbounds;
        _usage = usage;
        _config = config;
        _net = net;
        _protocols = protocols;
        _whoami = who;
        _host = host;
        _wsPath = wsPath;
        _ipsCtrl.text = ips;
        _domain = domain;
        _dashboard = dashboard;
        _online = online;
        _warp = warp;
        _subUrl = subUrl;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is PanelException ? e.message : e.toString();
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _flag(Map<String, dynamic> m, String k) => m[k] == true;

  /// Coerce the `{userId: count}` online map into plain ints.
  static Map<String, int> _parseOnline(Map<String, dynamic> raw) {
    final Map<String, int> out = <String, int>{};
    raw.forEach((String k, dynamic v) {
      final int n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      if (n > 0) out[k] = n;
    });
    return out;
  }

  // --- users --------------------------------------------------------------

  String _slug(String name) {
    final String s = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? newVpsUuid().substring(0, 8) : s;
  }

  String _displayName(Map<String, dynamic> u) {
    final String email = (u['email'] as String?)?.trim() ?? '';
    if (email.isNotEmpty) return email;
    return (u['id'] as String?)?.trim() ?? '';
  }

  /// Persist the current user list, then refresh usage. On error the caller has
  /// already mutated `_users`; a reload would resync, but we surface the failure
  /// so the user can retry the edit.
  Future<bool> _persistUsers() async {
    final PanelSession? session = _session;
    if (session == null) return false;
    setState(() => _savingUsers = true);
    final NovaStrings s = NovaStrings.of(context);
    try {
      await _panel.saveUsers(session, _users);
      final Map<String, int> usage = await _panel.usageByUser(session);
      if (!mounted) return true;
      setState(() => _usage = usage);
      _toast(s.vpsSaved);
      return true;
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
      return false;
    } finally {
      if (mounted) setState(() => _savingUsers = false);
    }
  }

  Future<void> _addUser() async {
    final _UserDraft? draft = await _openUserSheet();
    if (draft == null) return;
    final String slug = _slug(draft.name);
    final Map<String, dynamic> created = <String, dynamic>{
      'id': slug,
      'uuid': newVpsUuid(),
      'email': slug,
      'enabled': draft.enabled,
      'quotaBytes': draft.quotaBytes,
      'expiry': draft.expiry,
      'note': draft.note,
      'ipLimit': draft.ipLimit,
      'resetStrategy': draft.resetStrategy,
      'expireDays': draft.expireDays,
    };
    setState(() {
      _users = <Map<String, dynamic>>[..._users, created];
    });
    final bool ok = await _persistUsers();
    if (!ok || !mounted) return;
    // Offer to hand the new user their connection right away.
    final NovaStrings s = NovaStrings.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(s.vpsSaved),
          action: SnackBarAction(
            label: s.vpsShareLink,
            onPressed: () => _openShareSheet(created),
          ),
        ),
      );
  }

  Future<void> _editUser(int index) async {
    final Map<String, dynamic> current = _users[index];
    final _UserDraft? draft = await _openUserSheet(existing: current);
    if (draft == null) return;
    setState(() {
      current['email'] = draft.name.trim();
      current['quotaBytes'] = draft.quotaBytes;
      current['expiry'] = draft.expiry;
      current['enabled'] = draft.enabled;
      current['note'] = draft.note;
      current['ipLimit'] = draft.ipLimit;
      current['resetStrategy'] = draft.resetStrategy;
      current['expireDays'] = draft.expireDays;
    });
    await _persistUsers();
  }

  Future<void> _toggleUser(int index, bool value) async {
    setState(() => _users[index]['enabled'] = value);
    await _persistUsers();
  }

  Future<void> _deleteUser(int index) async {
    final NovaStrings s = NovaStrings.of(context);
    final bool ok = await _confirm(
      title: s.vpsDeleteUser,
      message: s.vpsDeleteUserConfirm,
      cancel: s.vpsCancel,
      confirm: s.vpsDelete,
      destructive: true,
    );
    if (!ok) return;
    setState(() {
      _users = <Map<String, dynamic>>[..._users]..removeAt(index);
    });
    await _persistUsers();
  }

  Future<_UserDraft?> _openUserSheet({Map<String, dynamic>? existing}) {
    return showModalBottomSheet<_UserDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => _UserSheet(existing: existing),
    );
  }

  /// Build this user's personal vless link and open the share sheet (QR + copy).
  Future<void> _openShareSheet(Map<String, dynamic> u) async {
    final String name = (u['email'] as String?)?.trim().isNotEmpty == true
        ? u['email'] as String
        : (u['id'] as String? ?? '');
    final String link = buildUserVlessLink(
      host: _host,
      wsPath: _wsPath,
      uuid: u['uuid'] as String? ?? '',
      name: name,
      insecure: widget.allowInsecure,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => _ShareSheet(link: link),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String cancel,
    required String confirm,
    bool destructive = false,
  }) async {
    final bool? r = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final nova = ctx.nova;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                confirm,
                style: destructive ? TextStyle(color: nova.danger) : null,
              ),
            ),
          ],
        );
      },
    );
    return r ?? false;
  }

  // --- inbounds -----------------------------------------------------------

  /// Best-effort refresh of the inbounds list after any change.
  Future<void> _reloadInbounds() async {
    final PanelSession? session = _session;
    if (session == null) return;
    try {
      final List<Map<String, dynamic>> list = await _panel.getInbounds(session);
      if (!mounted) return;
      setState(() => _inbounds = list);
    } catch (_) {/* leave the current list in place */}
  }

  Future<void> _addInbound() async {
    final Map<String, dynamic>? inbound = await _openInboundSheet();
    if (inbound == null) return;
    await _persistInbound(inbound, update: false);
  }

  Future<void> _editInbound(Map<String, dynamic> existing) async {
    final Map<String, dynamic>? inbound =
        await _openInboundSheet(existing: existing);
    if (inbound == null) return;
    await _persistInbound(inbound, update: true);
  }

  Future<void> _persistInbound(
    Map<String, dynamic> inbound, {
    required bool update,
  }) async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _savingInbounds = true);
    try {
      final Map<String, dynamic> res =
          await _panel.saveInbound(session, inbound, update: update);
      final List<dynamic>? list = res['inbounds'] as List<dynamic>?;
      if (mounted && list != null) {
        setState(() => _inbounds =
            list.whereType<Map<String, dynamic>>().toList());
      } else {
        await _reloadInbounds();
      }
      _toast(s.vpsSaved);
      // A freshly saved Reality inbound returns its generated public key.
      final Map<String, dynamic>? saved =
          (res['saved'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
      final Map<String, dynamic>? reality =
          (saved?['reality'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
      final String key = (reality?['publicKey'] as String?)?.trim() ?? '';
      if (key.isNotEmpty && mounted) await _showPublicKey(s, key);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _savingInbounds = false);
    }
  }

  Future<void> _toggleInbound(Map<String, dynamic> inbound) async {
    final PanelSession? session = _session;
    if (session == null) return;
    final String id = (inbound['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _savingInbounds = true);
    try {
      await _panel.toggleInbound(session, id);
      await _reloadInbounds();
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _savingInbounds = false);
    }
  }

  Future<void> _deleteInbound(Map<String, dynamic> inbound) async {
    final String id = (inbound['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return;
    final NovaStrings s = NovaStrings.of(context);
    final bool ok = await _confirm(
      title: s.inbDelete,
      message: s.inbDeleteConfirm,
      cancel: s.vpsCancel,
      confirm: s.vpsDelete,
      destructive: true,
    );
    if (!ok) return;
    final PanelSession? session = _session;
    if (session == null) return;
    setState(() => _savingInbounds = true);
    try {
      await _panel.deleteInbound(session, id);
      await _reloadInbounds();
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _savingInbounds = false);
    }
  }

  Future<Map<String, dynamic>?> _openInboundSheet(
      {Map<String, dynamic>? existing}) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => _InboundSheet(existing: existing),
    );
  }

  Future<void> _showPublicKey(NovaStrings s, String key) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        final nova = ctx.nova;
        return AlertDialog(
          title: Text(s.inbPublicKey),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(s.inbPublicKeyReady,
                  style: TextStyle(color: nova.muted)),
              const SizedBox(height: NovaSpace.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(NovaSpace.md),
                decoration: BoxDecoration(
                  color: nova.codeBg,
                  borderRadius: NovaRadii.smR,
                  border: Border.all(color: nova.border),
                ),
                child: SelectableText(
                  key,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(s.inbClose),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: key));
                if (ctx.mounted) Navigator.of(ctx).pop();
                _toast(s.vpsCopied);
              },
              child: Text(s.inbCopyKey),
            ),
          ],
        );
      },
    );
  }

  // --- inbounds tab -------------------------------------------------------

  Widget _inboundsTab(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    // "Insecure" when this node has no trusted cert: a no-domain VPS agent, or
    // a domain status that still reports a self-signed certificate.
    final bool insecure =
        widget.allowInsecure || _domain['tls'] == 'self-signed';
    final String tlsNote = insecure
        ? '${s.inbNoteTls} ${s.inbNoteTlsInsecure}'
        : s.inbNoteTls;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xxl),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(s.inbTitle,
                  style: text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (_savingInbounds)
              const Padding(
                padding: EdgeInsets.only(right: NovaSpace.sm),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            NovaButton(
              label: s.inbAdd,
              icon: Icons.add_rounded,
              variant: NovaButtonVariant.secondary,
              onPressed: _savingInbounds ? null : _addInbound,
            ),
          ],
        ),
        const SizedBox(height: NovaSpace.md),
        _inbNote(Icons.info_outline_rounded, s.inbNoteReality),
        const SizedBox(height: NovaSpace.sm),
        _inbNote(Icons.verified_user_outlined, tlsNote),
        const SizedBox(height: NovaSpace.md),
        if (_inbounds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NovaSpace.xl),
            child: Text(
              s.inbNone,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: nova.muted),
            ),
          )
        else
          for (final Map<String, dynamic> inbound in _inbounds) ...<Widget>[
            _inboundCard(s, inbound),
            const SizedBox(height: NovaSpace.md),
          ],
      ],
    );
  }

  Widget _inbNote(IconData icon, String message) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: nova.surface,
        borderRadius: NovaRadii.smR,
        border: Border.all(color: nova.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: nova.muted),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(message,
                style: text.bodySmall?.copyWith(color: nova.muted)),
          ),
        ],
      ),
    );
  }

  Widget _inboundCard(NovaStrings s, Map<String, dynamic> inbound) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool enabled = inbound['enabled'] != false;
    final String protocol = (inbound['protocol'] as String?)?.trim() ?? '';
    final String network = (inbound['network'] as String?)?.trim() ?? '';
    final String security = (inbound['security'] as String?)?.trim() ?? 'none';
    final int port = (inbound['port'] as num?)?.toInt() ?? 0;
    final String remark = (inbound['remark'] as String?)?.trim() ?? '';
    final String name =
        remark.isNotEmpty ? remark : '$protocol-$network-$security';
    final Map<String, dynamic>? reality =
        (inbound['reality'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
    final String pubKey = (reality?['publicKey'] as String?)?.trim() ?? '';

    final (String pillLabel, Color pillColor) = switch (security) {
      'reality' => (s.inbSecReality, nova.success),
      'tls' => (s.inbSecTls, nova.cyan),
      _ => (s.inbSecNone, nova.muted),
    };

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: _savingInbounds
                    ? null
                    : (bool _) => _toggleInbound(inbound),
              ),
              IconButton(
                tooltip: s.inbEdit,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_rounded, size: 20),
                onPressed:
                    _savingInbounds ? null : () => _editInbound(inbound),
              ),
              IconButton(
                tooltip: s.inbDelete,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: nova.danger),
                onPressed:
                    _savingInbounds ? null : () => _deleteInbound(inbound),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Row(
            children: <Widget>[
              NovaPill(label: pillLabel, color: pillColor, selected: true),
              const SizedBox(width: NovaSpace.sm),
              Icon(Icons.settings_ethernet_rounded, size: 14, color: nova.muted),
              const SizedBox(width: 6),
              Text('${s.inbPort} $port',
                  style: text.bodySmall?.copyWith(color: nova.muted)),
            ],
          ),
          if (pubKey.isNotEmpty) ...<Widget>[
            const SizedBox(height: NovaSpace.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NovaSpace.md),
              decoration: BoxDecoration(
                color: nova.codeBg,
                borderRadius: NovaRadii.smR,
                border: Border.all(color: nova.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(s.inbPublicKey,
                            style: text.labelSmall?.copyWith(color: nova.muted)),
                        const SizedBox(height: 2),
                        SelectableText(
                          pubKey,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: s.inbCopyKey,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.copy_rounded, size: 18, color: nova.cyan),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: pubKey));
                      _toast(s.vpsCopied);
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // --- settings persistence ----------------------------------------------

  Future<void> _saveConfig() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _saving = 'config');
    try {
      await _panel.saveConfig(session, _config);
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _saving = '');
    }
  }

  Future<void> _saveNet() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _saving = 'net');
    try {
      await _panel.saveNetworkSettings(session, _net);
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _saving = '');
    }
  }

  /// Toggle an optional protocol (vmess/trojan) and persist. VLESS stays on.
  /// The save reloads xray server-side, so the switches stay disabled until it
  /// returns; on failure the local value is reverted.
  Future<void> _toggleProtocol(String key, bool value) async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() {
      _protocols[key] = value;
      _savingProtocols = true;
    });
    try {
      await _panel.saveNetworkSettings(session, <String, dynamic>{
        'protocols': <String, dynamic>{
          'vless': true,
          'vmess': _protocols['vmess'] == true,
          'trojan': _protocols['trojan'] == true,
        },
      });
      _toast(s.vpsSaved);
    } catch (e) {
      if (mounted) setState(() => _protocols[key] = !value);
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _savingProtocols = false);
    }
  }

  Future<void> _saveIps() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _saving = 'ips');
    try {
      await _panel.saveIPs(session, _ipsCtrl.text);
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _saving = '');
    }
  }

  // --- domain & TLS -------------------------------------------------------

  /// The host to show in the status line: the one the node reports, falling
  /// back to the host parsed from network settings / the worker URL.
  String get _domainHost {
    final String reported = (_domain['host'] as String?)?.trim() ?? '';
    return reported.isNotEmpty ? reported : _host;
  }

  bool get _domainTrusted => _domain['tls'] == 'trusted';

  /// Kick off a domain switch, then poll status every 4s until it lands on
  /// `active` or `error`. The button stays disabled (spinner) the whole time.
  Future<void> _setupDomain() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    final String domain = _domainCtrl.text.trim();
    if (domain.isEmpty) {
      _toast(s.vpsDomainNeedDomain);
      return;
    }
    final bool origin = _domainMethod == 'origin';
    setState(() => _provisioning = true);
    try {
      await _panel.setDomain(
        session,
        domain: domain,
        method: _domainMethod,
        cert: origin ? _certCtrl.text.trim() : null,
        key: origin ? _keyCtrl.text.trim() : null,
        email: origin ? null : _emailCtrl.text.trim(),
      );
      while (mounted) {
        await Future<void>.delayed(const Duration(seconds: 4));
        if (!mounted) return;
        final Map<String, dynamic> st = await _panel.getDomainStatus(session);
        final String state = (st['state'] as String?)?.trim() ?? '';
        if (state == 'active') {
          if (!mounted) return;
          setState(() {
            _domain = st;
            _provisioning = false;
          });
          _toast('${s.vpsDomainActive} ${s.vpsDomainReconnectHint}');
          return;
        }
        if (state == 'error') {
          if (!mounted) return;
          setState(() {
            _domain = st;
            _provisioning = false;
          });
          final String err = (st['error'] as String?)?.trim() ?? '';
          _toast(err.isNotEmpty ? err : s.vpsDomainFailed);
          return;
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _provisioning = false);
      _toast(e is PanelException ? e.message : s.vpsDomainFailed);
    }
  }

  /// Revert the node back to its IP + self-signed certificate.
  Future<void> _removeDomain() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _provisioning = true);
    try {
      await _panel.clearDomain(session, _domainHost);
      final Map<String, dynamic> st = await _panel.getDomainStatus(session);
      if (!mounted) return;
      setState(() {
        _domain = st;
        _provisioning = false;
      });
      _toast(s.vpsSaved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _provisioning = false);
      _toast(e is PanelException ? e.message : s.vpsFailed);
    }
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          if (!_loading)
            IconButton(
              tooltip: s.nodeRefresh,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _load,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(s)
              : Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: NovaSegmentedTabs(
                            selected: _tab,
                            onChanged: (int i) => setState(() => _tab = i),
                            segments: <NovaSegment>[
                              NovaSegment(label: s.vpsTabOverview),
                              NovaSegment(label: s.vpsTabUsers),
                              NovaSegment(label: s.inbTab),
                              NovaSegment(label: s.vpsTabSettings),
                              NovaSegment(label: s.vpsTabInfo),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _tabBody(s)),
                  ],
                ),
    );
  }

  Widget _errorView(NovaStrings s) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(NovaSpace.xl),
            child: NovaCard(
              borderColor: context.nova.danger.withValues(alpha: 0.4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.error_outline_rounded, color: context.nova.danger),
                      const SizedBox(width: NovaSpace.sm),
                      Expanded(
                        child: Text(
                          s.vpsLoadFailed,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  if ((_error ?? '').isNotEmpty) ...<Widget>[
                    const SizedBox(height: NovaSpace.sm),
                    Text(_error!,
                        style: TextStyle(color: context.nova.muted)),
                  ],
                  const SizedBox(height: NovaSpace.md),
                  NovaButton(
                    label: s.vpsRetry,
                    icon: Icons.refresh_rounded,
                    variant: NovaButtonVariant.secondary,
                    expand: true,
                    onPressed: _load,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _tabBody(NovaStrings s) {
    final Widget body = switch (_tab) {
      0 => _overviewTab(s),
      1 => _usersTab(s),
      2 => _inboundsTab(s),
      3 => _settingsTab(s),
      _ => _infoTab(s),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: body,
      ),
    );
  }

  // --- overview tab -------------------------------------------------------

  Map<String, dynamic> _sysMap(String key) =>
      ((_dashboard['system'] as Map<dynamic, dynamic>?)?[key]
                  as Map<dynamic, dynamic>?)
              ?.cast<String, dynamic>() ??
          <String, dynamic>{};

  num? _sysNum(String parent, String child) {
    final Object? v = _sysMap(parent)[child];
    return v is num ? v : null;
  }

  Widget _overviewTab(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final Map<String, dynamic> system =
        (_dashboard['system'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    final Map<String, dynamic> geo = _sysMap('geo');
    final Map<String, dynamic> traffic =
        (_dashboard['traffic'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    final bool xrayUp = system['xray'] == true;

    final String city = (geo['city'] as String?)?.trim() ?? '';
    final String country = (geo['country'] as String?)?.trim() ?? '';
    final String isp = (geo['isp'] as String?)?.trim() ?? '';
    final String host = (_dashboard['host'] as String?)?.trim().isNotEmpty == true
        ? (_dashboard['host'] as String).trim()
        : _host;
    final List<String> place = <String>[
      if (city.isNotEmpty) city,
      if (country.isNotEmpty) country,
    ];
    final List<String> locLine = <String>[
      if (place.isNotEmpty) place.join(', '),
      if (isp.isNotEmpty) isp,
      if (host.isNotEmpty) host,
    ];

    // CPU
    final num? cpuPct = _sysNum('cpu', 'pct');
    final num? cores = _sysNum('cpu', 'cores');
    // Memory
    final num? memPct = _sysNum('mem', 'pct');
    final num? memUsed = _sysNum('mem', 'used');
    final num? memTotal = _sysNum('mem', 'total');
    // Disk
    final num? diskPct = _sysNum('disk', 'pct');
    // Uptime
    final Object? uptimeRaw = system['uptime'];
    final int uptime = uptimeRaw is num ? uptimeRaw.toInt() : 0;
    // Traffic
    final int trafficTotal = (traffic['total'] as num?)?.toInt() ?? 0;
    final int trafficToday = (traffic['today'] as num?)?.toInt() ?? 0;

    final List<Widget> stats = <Widget>[
      _statCard(
        icon: Icons.memory_rounded,
        label: s.vpsOvCpu,
        value: cpuPct == null ? s.vpsOvNa : '${cpuPct.round()}%',
        sub: cores == null ? null : s.vpsOvCores(cores.toInt()),
      ),
      _statCard(
        icon: Icons.developer_board_rounded,
        label: s.vpsOvMemory,
        value: memPct == null ? s.vpsOvNa : '${memPct.round()}%',
        sub: (memUsed != null && memTotal != null)
            ? '${_fmtBytes(memUsed.toInt())} / ${_fmtBytes(memTotal.toInt())}'
            : null,
      ),
      _statCard(
        icon: Icons.storage_rounded,
        label: s.vpsOvDisk,
        value: diskPct == null ? s.vpsOvNa : '${diskPct.round()}%',
      ),
      _statCard(
        icon: Icons.schedule_rounded,
        label: s.vpsOvUptime,
        value: uptime > 0 ? _fmtUptime(uptime) : s.vpsOvNa,
      ),
      _statCard(
        icon: Icons.swap_vert_rounded,
        label: s.vpsOvTraffic,
        value: _fmtBytes(trafficTotal),
        sub: s.vpsOvToday(_fmtBytes(trafficToday)),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xxl),
      children: <Widget>[
        NovaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.location_on_rounded, size: 18, color: nova.cyan),
                  const SizedBox(width: NovaSpace.sm),
                  Expanded(
                    child: Text(s.vpsOvLocation,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  NovaPill(
                    label: xrayUp ? s.vpsOvOperational : s.vpsOvOffline,
                    icon: xrayUp
                        ? Icons.check_circle_rounded
                        : Icons.pause_circle_rounded,
                    color: xrayUp ? nova.success : nova.muted,
                    selected: true,
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.sm),
              Text(
                locLine.isEmpty ? host : locLine.join('  '),
                style: text.bodyMedium?.copyWith(color: nova.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: NovaSpace.md),
        // Two-per-row stat grid. IntrinsicHeight bounds the row height so the
        // stretch (equal-height cards) is valid inside the scrolling ListView.
        for (int i = 0; i < stats.length; i += 2) ...<Widget>[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: stats[i]),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: i + 1 < stats.length
                      ? stats[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.md),
        ],
      ],
    );
  }

  Widget _statCard({
    required IconData icon,
    required String label,
    required String value,
    String? sub,
  }) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      padding: const EdgeInsets.all(NovaSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: nova.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(color: nova.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(
            value,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (sub != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              sub,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: nova.muted),
            ),
          ],
        ],
      ),
    );
  }

  // --- users tab ----------------------------------------------------------

  Widget _usersTab(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xxl),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(s.vpsUsers,
                  style: text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (_savingUsers)
              const Padding(
                padding: EdgeInsets.only(right: NovaSpace.sm),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            NovaButton(
              label: s.vpsAddUser,
              icon: Icons.person_add_rounded,
              variant: NovaButtonVariant.secondary,
              onPressed: _savingUsers ? null : _addUser,
            ),
          ],
        ),
        const SizedBox(height: NovaSpace.md),
        if (_users.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NovaSpace.xl),
            child: Text(
              s.vpsNoUsers,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: nova.muted),
            ),
          )
        else
          for (int i = 0; i < _users.length; i++) ...<Widget>[
            _userCard(s, i),
            const SizedBox(height: NovaSpace.md),
          ],
      ],
    );
  }

  Widget _userCard(NovaStrings s, int index) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final Map<String, dynamic> u = _users[index];
    final bool enabled = u['enabled'] != false;
    final int quota = (u['quotaBytes'] as num?)?.toInt() ?? 0;
    final int used = _usage[u['id']] ?? 0;
    final String expiry = (u['expiry'] as String?)?.trim() ?? '';
    final String quotaLabel =
        quota > 0 ? _fmtBytes(quota) : s.vpsUnlimited;
    final double ratio =
        quota > 0 ? (used / quota).clamp(0.0, 1.0).toDouble() : 0.0;
    final int onlineCount = _online[u['id']] ?? 0;

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _displayName(u),
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (onlineCount > 0) ...<Widget>[
                const SizedBox(width: NovaSpace.sm),
                NovaPill(
                  label: s.vpsOnlineCount(onlineCount),
                  icon: Icons.circle,
                  color: nova.success,
                  selected: true,
                ),
                const SizedBox(width: NovaSpace.sm),
              ],
              Switch(
                value: enabled,
                onChanged:
                    _savingUsers ? null : (bool v) => _toggleUser(index, v),
              ),
              IconButton(
                tooltip: s.vpsShareLink,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.ios_share_rounded, size: 20, color: nova.cyan),
                onPressed: () => _openShareSheet(u),
              ),
              IconButton(
                tooltip: s.vpsEditUser,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_rounded, size: 20),
                onPressed: _savingUsers ? null : () => _editUser(index),
              ),
              IconButton(
                tooltip: s.vpsDeleteUser,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: nova.danger),
                onPressed: _savingUsers ? null : () => _deleteUser(index),
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(
            '${s.vpsUserUsage}: ${_fmtBytes(used)} / $quotaLabel',
            style: text.bodySmall?.copyWith(color: nova.muted),
          ),
          if (quota > 0) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 6,
                backgroundColor: nova.surface2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  ratio >= 1.0 ? nova.danger : nova.cyan,
                ),
              ),
            ),
          ],
          if (expiry.isNotEmpty) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            Row(
              children: <Widget>[
                Icon(Icons.event_rounded, size: 14, color: nova.muted),
                const SizedBox(width: 6),
                Text(
                  '${s.vpsUserExpiry}: $expiry',
                  style: text.bodySmall?.copyWith(color: nova.muted),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // --- settings tab -------------------------------------------------------

  Widget _settingsTab(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xxl),
      children: <Widget>[
        _protocolsCard(s),
        const SizedBox(height: NovaSpace.md),
        _routingCard(s),
        const SizedBox(height: NovaSpace.md),
        _dnsCard(s),
        const SizedBox(height: NovaSpace.md),
        _censorCard(s),
        const SizedBox(height: NovaSpace.md),
        _limitsCard(s),
        const SizedBox(height: NovaSpace.md),
        _chainCard(s),
        const SizedBox(height: NovaSpace.md),
        _warpCard(s),
        const SizedBox(height: NovaSpace.md),
        _telegramCard(s),
        const SizedBox(height: NovaSpace.md),
        _maintenanceCard(s),
        const SizedBox(height: NovaSpace.md),
        _domainCard(s),
        const SizedBox(height: NovaSpace.md),
        _settingsCard(
          s,
          title: 'Config',
          saving: _saving == 'config',
          onSave: _saveConfig,
          children: <Widget>[
            _readonly('HOST', _config['HOST']?.toString() ?? ''),
            _readonly('UUID', _config['UUID']?.toString() ?? ''),
            for (final (String, String) t in _configToggles)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t.$2),
                value: _flag(_config, t.$1),
                onChanged: (bool v) => setState(() => _config[t.$1] = v),
              ),
          ],
        ),
        const SizedBox(height: NovaSpace.md),
        _settingsCard(
          s,
          title: 'Custom clean IPs',
          saving: _saving == 'ips',
          onSave: _saveIps,
          children: <Widget>[
            Text('One IP or host per line. Used to stamp fresh exits.',
                style: text.bodySmall?.copyWith(color: nova.muted)),
            const SizedBox(height: NovaSpace.sm),
            TextField(
              controller: _ipsCtrl,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                hintText: '104.16.0.0\n104.17.0.0',
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- settings cards: routing / DNS / anti-censorship / limits / chain ----

  Widget _netToggle(String title, String key, {String? hint}) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: hint == null
          ? null
          : Text(hint, style: text.bodySmall?.copyWith(color: nova.muted)),
      value: _flag(_net, key),
      onChanged: (bool v) => setState(() => _net[key] = v),
    );
  }

  Widget _routingCard(NovaStrings s) => _settingsCard(
        s,
        title: s.vpsRoutingTitle,
        saving: _saving == 'net',
        onSave: _saveNet,
        children: <Widget>[
          _netToggle(s.vpsRouteBlockAds, 'enableAdBlock'),
          _netToggle(s.vpsRouteBypassChina, 'bypassChina'),
          _netToggle(s.vpsRouteBypassRussia, 'bypassRussia'),
          _netToggle(s.vpsRouteBypassIran, 'enableDomesticBypass'),
          _netToggle(s.vpsRouteBlockQuic, 'blockQUIC'),
        ],
      );

  Widget _dnsCard(NovaStrings s) {
    final bool custom = (_net['antiSanctionDNSProvider']?.toString() ?? '') ==
        'custom';
    return _settingsCard(
      s,
      title: s.vpsDnsTitle,
      saving: _saving == 'net',
      onSave: _saveNet,
      children: <Widget>[
        _netToggle(s.vpsDnsDoh, 'enableDoH'),
        if (_flag(_net, 'enableDoH'))
          _dropdown(s.vpsDnsProvider, 'dohProvider', _dohProviders),
        _netToggle(s.vpsDnsAntiSanction, 'enableAntiSanctionDNS'),
        if (_flag(_net, 'enableAntiSanctionDNS')) ...<Widget>[
          _dropdown(s.vpsDnsAntiSanctionProvider, 'antiSanctionDNSProvider',
              _antiSanctionProviders),
          if (custom)
            _netText(s.vpsDnsCustom, 'antiSanctionCustomDNS',
                hint: '1.1.1.1', mono: true),
        ],
      ],
    );
  }

  Widget _censorCard(NovaStrings s) {
    final bool custom = (_net['tlsFragment']?.toString() ?? '') == 'custom';
    return _settingsCard(
      s,
      title: s.vpsCensorTitle,
      saving: _saving == 'net',
      onSave: _saveNet,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(child: Text(s.vpsTlsFragment)),
              DropdownButton<String>(
                value: custom ? 'custom' : 'off',
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                      value: 'off', child: Text(s.vpsTlsFragOff)),
                  DropdownMenuItem<String>(
                      value: 'custom', child: Text(s.vpsTlsFragCustom)),
                ],
                onChanged: (String? v) {
                  if (v == null) return;
                  setState(() => _net['tlsFragment'] = v);
                },
              ),
            ],
          ),
        ),
        if (custom) ...<Widget>[
          _fragText(s.vpsFragLength, 'length', hint: '100-200'),
          _fragText(s.vpsFragInterval, 'interval', hint: '10-20'),
          _fragText(s.vpsFragPackets, 'packets', hint: 'tlshello'),
        ],
      ],
    );
  }

  Widget _limitsCard(NovaStrings s) => _settingsCard(
        s,
        title: s.vpsLimitsTitle,
        saving: _saving == 'net',
        onSave: _saveNet,
        children: <Widget>[
          _number(s.vpsLimitMonthlyCap, 'monthlyCapGB'),
          _number(s.vpsLimitSpeed, 'speedLimitKBps'),
          _netToggle(s.vpsEnforceIpLimit, 'enforceIpLimit',
              hint: s.vpsEnforceIpLimitHint),
        ],
      );

  Widget _chainCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final String current = _net['chainProxy']?.toString() ?? '';
    return _settingsCard(
      s,
      title: s.vpsChainTitle,
      saving: _saving == 'net',
      onSave: _saveNet,
      children: <Widget>[
        Text(s.vpsChainSub,
            style: text.bodySmall?.copyWith(color: nova.muted)),
        const SizedBox(height: NovaSpace.sm),
        TextFormField(
          initialValue: current,
          maxLines: 4,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'socks5://127.0.0.1:1080\nhttp://127.0.0.1:8080',
          ),
          onChanged: (String v) => _net['chainProxy'] = v.trim(),
        ),
      ],
    );
  }

  /// A network-doc text field written straight to `_net[key]` on change (the
  /// same controller-free idiom as [_number] / [_dropdown]).
  Widget _netText(String label, String key,
      {String? hint, bool mono = false}) {
    final String current = _net[key]?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        initialValue: current,
        autocorrect: false,
        textCapitalization: TextCapitalization.none,
        style: mono
            ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
        onChanged: (String v) => _net[key] = v.trim(),
      ),
    );
  }

  /// A text field bound to a child of the `fragmentParams` object in `_net`.
  Widget _fragText(String label, String childKey, {String? hint}) {
    final Map<String, dynamic> fp =
        (_net['fragmentParams'] as Map<dynamic, dynamic>?)
                ?.cast<String, dynamic>() ??
            <String, dynamic>{};
    final String current = fp[childKey]?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        initialValue: current,
        autocorrect: false,
        textCapitalization: TextCapitalization.none,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
        onChanged: (String v) {
          final Map<String, dynamic> next =
              (_net['fragmentParams'] as Map<dynamic, dynamic>?)
                      ?.cast<String, dynamic>() ??
                  <String, dynamic>{};
          next[childKey] = v.trim();
          _net['fragmentParams'] = next;
        },
      ),
    );
  }

  // --- settings cards: WARP ----------------------------------------------

  Widget _warpCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool registered = _warp['registered'] == true;
    final String endpoint = (_warp['endpoint'] as String?)?.trim() ?? '';
    final String addressV4 = (_warp['addressV4'] as String?)?.trim() ?? '';

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(s.vpsWarpTitle,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              NovaPill(
                label: registered ? s.vpsWarpRegistered : s.vpsWarpNoAccount,
                icon: registered
                    ? Icons.verified_rounded
                    : Icons.cloud_off_rounded,
                color: registered ? nova.success : nova.muted,
                selected: true,
              ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsWarpSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          if (registered && (endpoint.isNotEmpty || addressV4.isNotEmpty)) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NovaSpace.md),
              decoration: BoxDecoration(
                color: nova.surface,
                borderRadius: NovaRadii.smR,
                border: Border.all(color: nova.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (endpoint.isNotEmpty)
                    SelectableText(endpoint,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  if (addressV4.isNotEmpty)
                    SelectableText(addressV4,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                ],
              ),
            ),
          ],
          const SizedBox(height: NovaSpace.md),
          if (_warpBusy)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: NovaSpace.sm),
                Text(s.vpsWarpRegistering,
                    style: text.bodyMedium?.copyWith(color: nova.muted)),
              ],
            )
          else if (!registered)
            NovaButton(
              label: s.vpsWarpRegister,
              icon: Icons.cloud_download_rounded,
              variant: NovaButtonVariant.secondary,
              expand: true,
              onPressed: _registerWarp,
            )
          else
            NovaButton(
              label: s.vpsWarpRemove,
              icon: Icons.link_off_rounded,
              variant: NovaButtonVariant.danger,
              expand: true,
              onPressed: _clearWarp,
            ),
          const Divider(height: NovaSpace.xl),
          if (!registered)
            Padding(
              padding: const EdgeInsets.only(bottom: NovaSpace.sm),
              child: Text(s.vpsWarpNeedAccount,
                  style: text.bodySmall?.copyWith(color: nova.warning)),
            ),
          _netToggle(s.vpsWarpEnable, 'enableWarp'),
          _netToggle(s.vpsWarpCalls, 'warpCalls'),
          _dropdown(s.vpsWarpMode, 'warpMode', _warpModes),
          _netText(s.vpsWarpEndpoint, 'warpEndpoint',
              hint: 'engage.cloudflareclient.com:2408', mono: true),
          const SizedBox(height: NovaSpace.sm),
          if (_saving == 'net')
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            NovaButton(
              label: s.vpsSave,
              icon: Icons.save_outlined,
              variant: NovaButtonVariant.secondary,
              expand: true,
              onPressed: _saveNet,
            ),
        ],
      ),
    );
  }

  Future<void> _registerWarp() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _warpBusy = true);
    try {
      await _panel.registerWarp(session);
      final Map<String, dynamic> warp = await _panel.getWarp(session);
      if (!mounted) return;
      setState(() => _warp = warp);
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsWarpRegisterFailed);
    } finally {
      if (mounted) setState(() => _warpBusy = false);
    }
  }

  Future<void> _clearWarp() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _warpBusy = true);
    try {
      await _panel.clearWarp(session);
      final Map<String, dynamic> warp = await _panel.getWarp(session);
      if (!mounted) return;
      setState(() => _warp = warp);
      _toast(s.vpsSaved);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsFailed);
    } finally {
      if (mounted) setState(() => _warpBusy = false);
    }
  }

  // --- settings cards: Telegram alerts -----------------------------------

  Widget _telegramCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(s.vpsTgTitle,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (_saving == 'net')
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                NovaButton(
                  label: s.vpsSave,
                  icon: Icons.save_outlined,
                  variant: NovaButtonVariant.secondary,
                  onPressed: _saveNet,
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsTgSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.sm),
          _netToggle(s.vpsTgEnable, 'enableTelegram'),
          _netText(s.vpsTgToken, 'tgBotToken', hint: '123456:ABC…', mono: true),
          _netText(s.vpsTgChatId, 'tgChatId', hint: '123456789', mono: true),
          const SizedBox(height: NovaSpace.sm),
          if (_tgBusy)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            NovaButton(
              label: s.vpsTgTest,
              icon: Icons.send_rounded,
              variant: NovaButtonVariant.ghost,
              expand: true,
              onPressed: _telegramTest,
            ),
        ],
      ),
    );
  }

  /// Persist the current network settings (so the bot token/chat id are saved)
  /// and then ask the node to send a Telegram test message.
  Future<void> _telegramTest() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _tgBusy = true);
    try {
      await _panel.saveNetworkSettings(session, _net);
      await _panel.telegramTest(session);
      _toast(s.vpsTgTestOk);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsTgTestFailed);
    } finally {
      if (mounted) setState(() => _tgBusy = false);
    }
  }

  // --- settings cards: backup & maintenance ------------------------------

  Widget _maintenanceCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(s.vpsMaintTitle,
              style:
                  text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsMaintSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          if (_maintBusy)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...<Widget>[
            NovaButton(
              label: s.vpsBackupDownload,
              icon: Icons.download_rounded,
              variant: NovaButtonVariant.secondary,
              expand: true,
              onPressed: _downloadBackup,
            ),
            const SizedBox(height: NovaSpace.sm),
            NovaButton(
              label: s.vpsRestore,
              icon: Icons.settings_backup_restore_rounded,
              variant: NovaButtonVariant.secondary,
              expand: true,
              onPressed: _restoreBackup,
            ),
            const SizedBox(height: NovaSpace.sm),
            NovaButton(
              label: s.vpsUpdateAgent,
              icon: Icons.system_update_alt_rounded,
              variant: NovaButtonVariant.ghost,
              expand: true,
              onPressed: _updateAgent,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadBackup() async {
    final PanelSession? session = _session;
    if (session == null) return;
    final NovaStrings s = NovaStrings.of(context);
    setState(() => _maintBusy = true);
    try {
      final Map<String, dynamic> dump = await _panel.backup(session);
      final String jsonStr = const JsonEncoder.withIndent('  ').convert(dump);
      await Clipboard.setData(ClipboardData(text: jsonStr));
      _toast(s.vpsBackupCopied);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsBackupFailed);
    } finally {
      if (mounted) setState(() => _maintBusy = false);
    }
  }

  Future<void> _restoreBackup() async {
    final NovaStrings s = NovaStrings.of(context);
    final String? pasted = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => const _RestoreSheet(),
    );
    if (pasted == null || pasted.trim().isEmpty) return;
    Map<String, dynamic> dump;
    try {
      final Object? decoded = jsonDecode(pasted.trim());
      if (decoded is! Map) throw const FormatException('not an object');
      dump = decoded.cast<String, dynamic>();
    } catch (_) {
      _toast(s.vpsRestoreInvalid);
      return;
    }
    final bool ok = await _confirm(
      title: s.vpsRestore,
      message: s.vpsRestoreConfirm,
      cancel: s.vpsCancel,
      confirm: s.vpsRestore,
      destructive: true,
    );
    if (!ok) return;
    final PanelSession? session = _session;
    if (session == null) return;
    setState(() => _maintBusy = true);
    try {
      await _panel.restore(session, dump);
      if (!mounted) return;
      _toast(s.vpsRestoreDone);
      await _load();
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsRestoreFailed);
    } finally {
      if (mounted) setState(() => _maintBusy = false);
    }
  }

  Future<void> _updateAgent() async {
    final NovaStrings s = NovaStrings.of(context);
    final bool ok = await _confirm(
      title: s.vpsUpdateAgent,
      message: s.vpsUpdateAgentConfirm,
      cancel: s.vpsCancel,
      confirm: s.vpsUpdateAgent,
    );
    if (!ok) return;
    final PanelSession? session = _session;
    if (session == null) return;
    setState(() => _maintBusy = true);
    try {
      await _panel.selfUpdate(session);
      _toast(s.vpsUpdateAgentStarted);
    } catch (e) {
      _toast(e is PanelException ? e.message : s.vpsUpdateAgentFailed);
    } finally {
      if (mounted) setState(() => _maintBusy = false);
    }
  }

  Widget _protocolsCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool vmess = _protocols['vmess'] == true;
    final bool trojan = _protocols['trojan'] == true;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(s.vpsProtocols,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (_savingProtocols)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsProtocolsSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.sm),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: true,
            onChanged: null,
            title: Row(
              children: <Widget>[
                Flexible(child: Text(s.vpsProtoVless)),
                const SizedBox(width: NovaSpace.sm),
                NovaPill(label: s.vpsProtoAlwaysOn),
              ],
            ),
            subtitle: Text(s.vpsProtoVlessSub,
                style: text.bodySmall?.copyWith(color: nova.muted)),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: vmess,
            onChanged: _savingProtocols
                ? null
                : (bool v) => _toggleProtocol('vmess', v),
            title: Text(s.vpsProtoVmess),
            subtitle: Text(s.vpsProtoVmessSub,
                style: text.bodySmall?.copyWith(color: nova.muted)),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: trojan,
            onChanged: _savingProtocols
                ? null
                : (bool v) => _toggleProtocol('trojan', v),
            title: Text(s.vpsProtoTrojan),
            subtitle: Text(s.vpsProtoTrojanSub,
                style: text.bodySmall?.copyWith(color: nova.muted)),
          ),
        ],
      ),
    );
  }

  Widget _domainCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool trusted = _domainTrusted;
    final String host = _domainHost;
    final bool origin = _domainMethod == 'origin';

    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(s.vpsDomainTitle,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (trusted)
                NovaPill(
                  label: s.vpsDomainTrustedPill,
                  icon: Icons.verified_rounded,
                  color: nova.success,
                  selected: true,
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsDomainSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NovaSpace.md),
            decoration: BoxDecoration(
              color: nova.surface,
              borderRadius: NovaRadii.smR,
              border: Border.all(color: nova.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  trusted ? Icons.lock_rounded : Icons.lock_outline_rounded,
                  size: 18,
                  color: trusted ? nova.success : nova.muted,
                ),
                const SizedBox(width: NovaSpace.sm),
                Expanded(
                  child: Text(
                    trusted
                        ? s.vpsDomainTrusted(host)
                        : s.vpsDomainSelfSigned(host),
                    style: text.bodySmall?.copyWith(color: nova.text),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: NovaSpace.md),
          TextField(
            controller: _domainCtrl,
            autocorrect: false,
            enabled: !_provisioning,
            keyboardType: TextInputType.url,
            textCapitalization: TextCapitalization.none,
            decoration: InputDecoration(
              labelText: s.vpsDomainField,
              hintText: 'vpn.example.com',
            ),
          ),
          const SizedBox(height: NovaSpace.md),
          NovaSegmentedTabs(
            selected: origin ? 1 : 0,
            onChanged: _provisioning
                ? (int _) {}
                : (int i) => setState(
                    () => _domainMethod = i == 1 ? 'origin' : 'letsencrypt'),
            segments: <NovaSegment>[
              NovaSegment(label: s.vpsDomainMethodAuto),
              NovaSegment(label: s.vpsDomainMethodOrigin),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          Text(
            origin ? s.vpsDomainMethodOriginHelp : s.vpsDomainMethodAutoHelp,
            style: text.bodySmall?.copyWith(color: nova.muted),
          ),
          if (origin) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            TextField(
              controller: _certCtrl,
              enabled: !_provisioning,
              maxLines: 5,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: s.vpsDomainCert,
                alignLabelWithHint: true,
                hintText: '-----BEGIN CERTIFICATE-----',
              ),
            ),
            const SizedBox(height: NovaSpace.md),
            TextField(
              controller: _keyCtrl,
              enabled: !_provisioning,
              maxLines: 5,
              autocorrect: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: s.vpsDomainKey,
                alignLabelWithHint: true,
                hintText: '-----BEGIN PRIVATE KEY-----',
              ),
            ),
          ] else ...<Widget>[
            const SizedBox(height: NovaSpace.md),
            TextField(
              controller: _emailCtrl,
              enabled: !_provisioning,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: s.vpsDomainEmail,
                hintText: 'you@example.com',
              ),
            ),
          ],
          const SizedBox(height: NovaSpace.lg),
          if (_provisioning)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: NovaSpace.sm),
                Text(s.vpsDomainWorking,
                    style: text.bodyMedium?.copyWith(color: nova.muted)),
              ],
            )
          else ...<Widget>[
            NovaButton(
              label: s.vpsDomainSetup,
              icon: Icons.verified_user_outlined,
              expand: true,
              onPressed: _setupDomain,
            ),
            if (trusted) ...<Widget>[
              const SizedBox(height: NovaSpace.sm),
              NovaButton(
                label: s.vpsDomainRemove,
                icon: Icons.link_off_rounded,
                variant: NovaButtonVariant.danger,
                expand: true,
                onPressed: _removeDomain,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _settingsCard(
    NovaStrings s, {
    required String title,
    required List<Widget> children,
    required bool saving,
    required VoidCallback onSave,
  }) {
    final text = Theme.of(context).textTheme;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (saving)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                NovaButton(
                  label: s.vpsSave,
                  icon: Icons.save_outlined,
                  variant: NovaButtonVariant.secondary,
                  onPressed: onSave,
                ),
            ],
          ),
          const SizedBox(height: NovaSpace.sm),
          ...children,
        ],
      ),
    );
  }

  Widget _readonly(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 64,
              child: Text(label,
                  style:
                      TextStyle(color: context.nova.muted, fontSize: 13)),
            ),
            Expanded(
              child: SelectableText(
                value.isEmpty ? '-' : value,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      );

  Widget _dropdown(String label, String key, List<String> options) {
    final String current = (_net[key]?.toString() ?? '').isNotEmpty
        ? _net[key].toString()
        : options.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          DropdownButton<String>(
            value: options.contains(current) ? current : options.first,
            items: options
                .map((String o) =>
                    DropdownMenuItem<String>(value: o, child: Text(o)))
                .toList(),
            onChanged: (String? v) {
              if (v != null) setState(() => _net[key] = v);
            },
          ),
        ],
      ),
    );
  }

  Widget _number(String label, String key) {
    final int value = (_net[key] is num) ? (_net[key] as num).toInt() : 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          SizedBox(
            width: 90,
            child: TextFormField(
              initialValue: '$value',
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              decoration: const InputDecoration(isDense: true),
              onChanged: (String v) =>
                  _net[key] = int.tryParse(v.trim()) ?? 0,
            ),
          ),
        ],
      ),
    );
  }

  // --- info tab -----------------------------------------------------------

  Widget _infoTab(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final Whoami? w = _whoami;
    final String base = _session?.workerUrl ?? widget.workerUrl;
    final String host = Uri.tryParse(base)?.host ?? base;
    final bool hasInfo = w != null &&
        (w.isp.isNotEmpty ||
            w.country.isNotEmpty ||
            w.city.isNotEmpty ||
            w.carrier.isNotEmpty ||
            w.asn != 0);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xxl),
      children: <Widget>[
        NovaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.dns_rounded, color: nova.cyan),
                  const SizedBox(width: NovaSpace.sm),
                  Expanded(
                    child: Text(widget.title,
                        style: text.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.md),
              if (hasInfo) ...<Widget>[
                if (w.isp.isNotEmpty) _infoRow('ISP', w.isp),
                if (w.country.isNotEmpty) _infoRow('Country', w.country),
                if (w.city.isNotEmpty) _infoRow('City', w.city),
                if (w.carrier.isNotEmpty) _infoRow('Carrier', w.carrier),
                if (w.asn != 0) _infoRow('ASN', 'AS${w.asn}'),
              ] else
                Text(
                  'Self-hosted node at $host. This box does not report a '
                  'public ISP or location, which is normal for a VPS you '
                  'run yourself.',
                  style: text.bodyMedium?.copyWith(color: nova.muted),
                ),
              const Divider(height: NovaSpace.xl),
              _infoRow('Address', base, mono: true),
            ],
          ),
        ),
        if (_subUrl.isNotEmpty) ...<Widget>[
          const SizedBox(height: NovaSpace.md),
          _subscriptionCard(s),
        ],
      ],
    );
  }

  /// A subscription card offering the node link in the three formats clients
  /// use: base64 (as-is), Clash, and sing-box. Each row is copyable.
  Widget _subscriptionCard(NovaStrings s) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool isUrl =
        _subUrl.startsWith('http://') || _subUrl.startsWith('https://');
    final String sep = _subUrl.contains('?') ? '&' : '?';
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(s.vpsSubTitle,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: NovaSpace.xs),
          Text(s.vpsSubSub,
              style: text.bodySmall?.copyWith(color: nova.muted)),
          const SizedBox(height: NovaSpace.md),
          _subRow(s, s.vpsSubBase, _subUrl),
          if (isUrl) ...<Widget>[
            const SizedBox(height: NovaSpace.sm),
            _subRow(s, s.vpsSubClash, '$_subUrl${sep}target=clash'),
            const SizedBox(height: NovaSpace.sm),
            _subRow(s, s.vpsSubSingbox, '$_subUrl${sep}target=singbox'),
          ],
        ],
      ),
    );
  }

  Widget _subRow(NovaStrings s, String label, String value) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: nova.codeBg,
        borderRadius: NovaRadii.smR,
        border: Border.all(color: nova.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label,
                    style: text.labelSmall?.copyWith(color: nova.muted)),
                const SizedBox(height: 2),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    value,
                    maxLines: 1,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: s.vpsCopyLink,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_rounded, size: 18, color: nova.cyan),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              _toast(s.vpsSubCopied);
            },
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool mono = false}) {
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(color: nova.muted, fontSize: 13)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats a byte count with decimal (1000-based) units, matching how per-user
/// quotas are stored (GB * 1e9).
String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  final String n =
      (i == 0 || v >= 100) ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$n ${units[i]}';
}

/// Formats an uptime in seconds as the two most significant units, e.g.
/// "3d 4h", "5h 12m", or "8m".
String _fmtUptime(int seconds) {
  if (seconds <= 0) return '0m';
  final int days = seconds ~/ 86400;
  final int hours = (seconds % 86400) ~/ 3600;
  final int mins = (seconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${mins}m';
  return '${mins}m';
}

/// The per-user share sheet: a scannable QR of the user's vless link on a fixed
/// white card (so it reads in dark mode), plus the raw link with a copy button.
class _ShareSheet extends StatelessWidget {
  const _ShareSheet({required this.link});

  final String link;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: nova.bgAlt,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: nova.border),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(NovaSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: nova.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: NovaSpace.lg),
              Text(s.vpsShareLink, style: text.titleLarge),
              const SizedBox(height: NovaSpace.lg),
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: NovaRadii.cardR,
                  ),
                  child: QrImageView(
                    data: link,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              Text(
                s.vpsQrHint,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: nova.muted),
              ),
              const SizedBox(height: NovaSpace.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(NovaSpace.md),
                decoration: BoxDecoration(
                  color: nova.codeBg,
                  borderRadius: NovaRadii.smR,
                  border: Border.all(color: nova.border),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    link,
                    maxLines: 1,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: NovaSpace.md),
              NovaButton(
                label: s.vpsCopyLink,
                icon: Icons.copy_rounded,
                expand: true,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(s.vpsSaved)));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The restore bottom sheet: a single paste-JSON field. Pops the pasted text
/// on restore, or null on cancel. (The app has no file picker dependency, so
/// backups round-trip through the clipboard as JSON text.)
class _RestoreSheet extends StatefulWidget {
  const _RestoreSheet();

  @override
  State<_RestoreSheet> createState() => _RestoreSheetState();
}

class _RestoreSheetState extends State<_RestoreSheet> {
  final TextEditingController _json = TextEditingController();

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: nova.bgAlt,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: nova.border),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: nova.border,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),
                Text(s.vpsRestore, style: text.titleLarge),
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _json,
                  maxLines: 8,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    labelText: s.vpsRestorePaste,
                    alignLabelWithHint: true,
                    hintText: '{ "settings": { … } }',
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: NovaButton(
                        label: s.vpsCancel,
                        variant: NovaButtonVariant.secondary,
                        expand: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: NovaSpace.md),
                    Expanded(
                      child: NovaButton(
                        label: s.vpsRestore,
                        icon: Icons.settings_backup_restore_rounded,
                        expand: true,
                        onPressed: () =>
                            Navigator.of(context).pop(_json.text),
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

/// The values collected from the add/edit user sheet.
class _UserDraft {
  _UserDraft({
    required this.name,
    required this.quotaBytes,
    required this.expiry,
    required this.enabled,
    required this.note,
    required this.ipLimit,
    required this.resetStrategy,
    required this.expireDays,
  });

  final String name;
  final int quotaBytes;
  final String expiry;
  final bool enabled;

  /// Free-text note stored on the user object.
  final String note;

  /// Max simultaneous devices (0 = unlimited).
  final int ipLimit;

  /// One of 'none' | 'day' | 'week' | 'month'.
  final String resetStrategy;

  /// Auto-expire this many days after the user's first connection (0 = off).
  final int expireDays;
}

/// The add/edit user bottom sheet: name, data limit (GB, 0 = unlimited), an
/// optional expiry date, and an enabled switch. Pops a [_UserDraft] on save.
class _UserSheet extends StatefulWidget {
  const _UserSheet({this.existing});

  final Map<String, dynamic>? existing;

  @override
  State<_UserSheet> createState() => _UserSheetState();
}

class _UserSheetState extends State<_UserSheet> {
  static const List<String> _resetStrategies = <String>[
    'none',
    'day',
    'week',
    'month',
  ];

  late final TextEditingController _name;
  late final TextEditingController _quota;
  late final TextEditingController _note;
  late final TextEditingController _ipLimit;
  late final TextEditingController _expireDays;
  String _expiry = '';
  bool _enabled = true;
  String _reset = 'none';

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.existing;
    final String initialName = e == null
        ? ''
        : ((e['email'] as String?)?.trim().isNotEmpty == true
            ? (e['email'] as String)
            : (e['id'] as String? ?? ''));
    final int quotaBytes =
        e == null ? 0 : ((e['quotaBytes'] as num?)?.toInt() ?? 0);
    final int ipLimit = e == null ? 0 : ((e['ipLimit'] as num?)?.toInt() ?? 0);
    final int expireDays =
        e == null ? 0 : ((e['expireDays'] as num?)?.toInt() ?? 0);
    _name = TextEditingController(text: initialName);
    _quota = TextEditingController(
        text: quotaBytes > 0 ? _gbString(quotaBytes) : '');
    _note = TextEditingController(text: (e?['note'] as String?)?.trim() ?? '');
    _ipLimit =
        TextEditingController(text: ipLimit > 0 ? '$ipLimit' : '');
    _expireDays =
        TextEditingController(text: expireDays > 0 ? '$expireDays' : '');
    _expiry = e == null ? '' : ((e['expiry'] as String?)?.trim() ?? '');
    _enabled = e == null ? true : (e['enabled'] != false);
    final String reset = (e?['resetStrategy'] as String?)?.trim() ?? 'none';
    _reset = _resetStrategies.contains(reset) ? reset : 'none';
  }

  static String _gbString(int bytes) {
    final double gb = bytes / 1000000000;
    if (gb == gb.roundToDouble()) return gb.toStringAsFixed(0);
    return gb.toStringAsFixed(1);
  }

  @override
  void dispose() {
    _name.dispose();
    _quota.dispose();
    _note.dispose();
    _ipLimit.dispose();
    _expireDays.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    DateTime initial = now;
    if (_expiry.isNotEmpty) {
      final DateTime? parsed = DateTime.tryParse(_expiry);
      if (parsed != null) initial = parsed;
    }
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    final String iso =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    setState(() => _expiry = iso);
  }

  void _save() {
    final double gb = double.tryParse(_quota.text.trim()) ?? 0;
    final int quotaBytes = gb <= 0 ? 0 : (gb * 1000000000).round();
    final int ipLimit = int.tryParse(_ipLimit.text.trim()) ?? 0;
    final int expireDays = int.tryParse(_expireDays.text.trim()) ?? 0;
    Navigator.of(context).pop(_UserDraft(
      name: _name.text,
      quotaBytes: quotaBytes,
      expiry: _expiry,
      enabled: _enabled,
      note: _note.text.trim(),
      ipLimit: ipLimit < 0 ? 0 : ipLimit,
      resetStrategy: _reset,
      expireDays: expireDays < 0 ? 0 : expireDays,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool editing = widget.existing != null;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: nova.bgAlt,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: nova.border),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: nova.border,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),
                Text(
                  editing ? s.vpsEditUser : s.vpsAddUser,
                  style: text.titleLarge,
                ),
                const SizedBox(height: NovaSpace.lg),
                TextField(
                  controller: _name,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(labelText: s.vpsUserName),
                ),
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _quota,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: s.vpsUserQuotaGb,
                    hintText: '0',
                    helperText: s.vpsUnlimited,
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: s.vpsUserExpiry,
                    suffixIcon: _expiry.isEmpty
                        ? const Icon(Icons.event_rounded)
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () => setState(() => _expiry = ''),
                          ),
                  ),
                  child: InkWell(
                    onTap: _pickDate,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        _expiry.isEmpty ? s.vpsNoExpiry : _expiry,
                        style: text.bodyMedium?.copyWith(
                          color: _expiry.isEmpty ? nova.muted : nova.text,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _ipLimit,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: s.vpsUserDeviceLimit,
                    hintText: '0',
                    helperText: s.vpsUserDeviceLimitHint,
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                InputDecorator(
                  decoration: InputDecoration(labelText: s.vpsUserDataReset),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _reset,
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                            value: 'none', child: Text(s.vpsResetNone)),
                        DropdownMenuItem<String>(
                            value: 'day', child: Text(s.vpsResetDay)),
                        DropdownMenuItem<String>(
                            value: 'week', child: Text(s.vpsResetWeek)),
                        DropdownMenuItem<String>(
                            value: 'month', child: Text(s.vpsResetMonth)),
                      ],
                      onChanged: (String? v) {
                        if (v != null) setState(() => _reset = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _expireDays,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: s.vpsUserExpireDays,
                    hintText: '0',
                    helperText: s.vpsUserExpireDaysHint,
                  ),
                ),
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _note,
                  decoration: InputDecoration(labelText: s.vpsUserNote),
                ),
                const SizedBox(height: NovaSpace.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _enabled,
                  onChanged: (bool v) => setState(() => _enabled = v),
                  title: Text(s.vpsUserEnabled,
                      style: text.bodyMedium),
                ),
                const SizedBox(height: NovaSpace.lg),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: NovaButton(
                        label: s.vpsCancel,
                        variant: NovaButtonVariant.secondary,
                        expand: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: NovaSpace.md),
                    Expanded(
                      child: NovaButton(
                        label: s.vpsSave,
                        icon: Icons.check_rounded,
                        expand: true,
                        onPressed: _save,
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

/// The six inbound presets mirrored from the web panel's inbounds manager.
enum _InbPreset {
  realityVision,
  trojanReality,
  grpcTls,
  xhttpTls,
  wsTls,
  ss2022,
}

const List<_InbPreset> _inbPresetOrder = <_InbPreset>[
  _InbPreset.realityVision,
  _InbPreset.trojanReality,
  _InbPreset.grpcTls,
  _InbPreset.xhttpTls,
  _InbPreset.wsTls,
  _InbPreset.ss2022,
];

/// The fixed protocol/transport a preset locks in, plus which human fields the
/// editor collects for it. The node fills everything else (Reality keys, dest,
/// short IDs, the Shadowsocks password).
class _InbSpec {
  const _InbSpec({
    required this.protocol,
    required this.network,
    required this.security,
    this.flow = '',
    this.method,
    required this.defaultPort,
    this.reality = false,
    this.needsSni = false,
    this.sniBorrow = false,
    this.needsServiceName = false,
    this.needsPath = false,
    this.needsMode = false,
  });

  final String protocol;
  final String network;
  final String security;
  final String flow;
  final String? method;
  final int defaultPort;
  final bool reality;
  final bool needsSni;
  final bool sniBorrow;
  final bool needsServiceName;
  final bool needsPath;
  final bool needsMode;
}

_InbSpec _inbSpec(_InbPreset p) => switch (p) {
      _InbPreset.realityVision => const _InbSpec(
          protocol: 'vless',
          network: 'tcp',
          security: 'reality',
          flow: 'xtls-rprx-vision',
          defaultPort: 8443,
          reality: true,
          needsSni: true,
          sniBorrow: true,
        ),
      _InbPreset.trojanReality => const _InbSpec(
          protocol: 'trojan',
          network: 'grpc',
          security: 'reality',
          defaultPort: 8443,
          reality: true,
          needsSni: true,
          sniBorrow: true,
          needsServiceName: true,
        ),
      _InbPreset.grpcTls => const _InbSpec(
          protocol: 'vless',
          network: 'grpc',
          security: 'tls',
          defaultPort: 8443,
          needsSni: true,
          needsServiceName: true,
        ),
      _InbPreset.xhttpTls => const _InbSpec(
          protocol: 'vless',
          network: 'xhttp',
          security: 'tls',
          defaultPort: 8443,
          needsSni: true,
          needsPath: true,
          needsMode: true,
        ),
      _InbPreset.wsTls => const _InbSpec(
          protocol: 'vless',
          network: 'ws',
          security: 'tls',
          defaultPort: 8443,
          needsSni: true,
          needsPath: true,
        ),
      _InbPreset.ss2022 => const _InbSpec(
          protocol: 'shadowsocks',
          network: 'tcp',
          security: 'none',
          method: '2022-blake3-aes-128-gcm',
          defaultPort: 8443,
        ),
    };

_InbPreset _presetFromInbound(Map<String, dynamic> e) {
  final String protocol = (e['protocol'] as String?)?.trim() ?? '';
  final String security = (e['security'] as String?)?.trim() ?? '';
  final String network = (e['network'] as String?)?.trim() ?? '';
  if (protocol == 'shadowsocks') return _InbPreset.ss2022;
  if (security == 'reality') {
    return protocol == 'trojan'
        ? _InbPreset.trojanReality
        : _InbPreset.realityVision;
  }
  if (network == 'grpc') return _InbPreset.grpcTls;
  if (network == 'xhttp') return _InbPreset.xhttpTls;
  if (network == 'ws') return _InbPreset.wsTls;
  return _InbPreset.realityVision;
}

String _presetTitle(NovaStrings s, _InbPreset p) => switch (p) {
      _InbPreset.realityVision => s.inbPresetRealityVision,
      _InbPreset.trojanReality => s.inbPresetTrojanReality,
      _InbPreset.grpcTls => s.inbPresetGrpcTls,
      _InbPreset.xhttpTls => s.inbPresetXhttpTls,
      _InbPreset.wsTls => s.inbPresetWsTls,
      _InbPreset.ss2022 => s.inbPresetSs2022,
    };

String _presetSub(NovaStrings s, _InbPreset p) => switch (p) {
      _InbPreset.realityVision => s.inbPresetRealityVisionSub,
      _InbPreset.trojanReality => s.inbPresetTrojanRealitySub,
      _InbPreset.grpcTls => s.inbPresetGrpcTlsSub,
      _InbPreset.xhttpTls => s.inbPresetXhttpTlsSub,
      _InbPreset.wsTls => s.inbPresetWsTlsSub,
      _InbPreset.ss2022 => s.inbPresetSs2022Sub,
    };

/// A default routing path for the transports that use one.
String _defaultInbPath(_InbPreset p) =>
    (p == _InbPreset.wsTls || p == _InbPreset.xhttpTls) ? '/nova' : '';

/// The add/edit inbound bottom sheet: a preset picker (locked on edit) plus the
/// few human fields the chosen preset needs. Pops the assembled inbound map on
/// save, or null on cancel.
class _InboundSheet extends StatefulWidget {
  const _InboundSheet({this.existing});

  final Map<String, dynamic>? existing;

  @override
  State<_InboundSheet> createState() => _InboundSheetState();
}

class _InboundSheetState extends State<_InboundSheet> {
  static const List<String> _xhttpModes = <String>[
    'auto',
    'packet-up',
    'stream-up',
  ];
  static const List<String> _sniSuggestions = <String>[
    'www.microsoft.com',
    'www.cloudflare.com',
    'www.apple.com',
  ];

  late _InbPreset _preset;
  late final TextEditingController _port;
  late final TextEditingController _sni;
  late final TextEditingController _serviceName;
  late final TextEditingController _path;
  late final TextEditingController _remark;
  String _xhttpMode = 'auto';
  String? _portError;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? e = widget.existing;
    _preset = e == null ? _InbPreset.realityVision : _presetFromInbound(e);
    final _InbSpec spec = _inbSpec(_preset);
    final int port = e == null
        ? spec.defaultPort
        : ((e['port'] as num?)?.toInt() ?? spec.defaultPort);
    String sni = '';
    if (e != null) {
      if (spec.reality) {
        final Map<String, dynamic>? r =
            (e['reality'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>();
        final List<dynamic>? names = r?['serverNames'] as List<dynamic>?;
        sni = (names != null && names.isNotEmpty)
            ? names.first.toString()
            : '';
      } else {
        sni = (e['sni'] as String?)?.trim() ?? '';
      }
    }
    _port = TextEditingController(text: '$port');
    _sni = TextEditingController(text: sni);
    _serviceName =
        TextEditingController(text: (e?['serviceName'] as String?)?.trim() ?? '');
    _path = TextEditingController(
      text: (e?['path'] as String?)?.trim() ??
          (e == null ? _defaultInbPath(_preset) : ''),
    );
    _remark =
        TextEditingController(text: (e?['remark'] as String?)?.trim() ?? '');
    final String mode = (e?['xhttpMode'] as String?)?.trim() ?? '';
    _xhttpMode = _xhttpModes.contains(mode) ? mode : 'auto';
  }

  @override
  void dispose() {
    _port.dispose();
    _sni.dispose();
    _serviceName.dispose();
    _path.dispose();
    _remark.dispose();
    super.dispose();
  }

  void _onPreset(_InbPreset p) {
    setState(() {
      _preset = p;
      final _InbSpec spec = _inbSpec(p);
      _port.text = '${spec.defaultPort}';
      if (spec.needsPath && _path.text.trim().isEmpty) {
        _path.text = _defaultInbPath(p);
      }
      _portError = null;
    });
  }

  void _save() {
    final NovaStrings s = NovaStrings.of(context);
    final _InbSpec spec = _inbSpec(_preset);
    final int port = int.tryParse(_port.text.trim()) ?? -1;
    if (port < 1 || port > 65535) {
      setState(() => _portError = s.inbPortInvalid);
      return;
    }
    final Map<String, dynamic>? e = widget.existing;
    final Map<String, dynamic> map = <String, dynamic>{
      if (e != null && e['id'] is String) 'id': e['id'],
      'enabled': e == null ? true : (e['enabled'] != false),
      'protocol': spec.protocol,
      'network': spec.network,
      'security': spec.security,
      'port': port,
      if (spec.flow.isNotEmpty) 'flow': spec.flow,
      if (spec.method != null) 'method': spec.method,
    };
    final String remark = _remark.text.trim();
    if (remark.isNotEmpty) map['remark'] = remark;
    if (spec.needsServiceName) {
      final String v = _serviceName.text.trim();
      if (v.isNotEmpty) map['serviceName'] = v;
    }
    if (spec.needsPath) {
      final String v = _path.text.trim();
      if (v.isNotEmpty) map['path'] = v;
    }
    if (spec.needsMode) map['xhttpMode'] = _xhttpMode;
    if (spec.needsSni) {
      final String sni = _sni.text.trim();
      if (spec.reality) {
        // Preserve any existing keypair/dest/shortIds so an edit keeps them;
        // the node regenerates only what is missing.
        final Map<String, dynamic> existingR =
            (e?['reality'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        map['reality'] = <String, dynamic>{
          ...existingR,
          'serverNames': <String>[if (sni.isNotEmpty) sni],
        };
      } else if (sni.isNotEmpty) {
        map['sni'] = sni;
      }
    }
    Navigator.of(context).pop(map);
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final _InbSpec spec = _inbSpec(_preset);
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: nova.bgAlt,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: nova.border),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NovaSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: nova.border,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: NovaSpace.lg),
                Text(_editing ? s.inbEdit : s.inbAdd, style: text.titleLarge),
                const SizedBox(height: NovaSpace.lg),
                if (_editing)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: NovaPill(
                      label: _presetTitle(s, _preset),
                      color: nova.cyan,
                      selected: true,
                    ),
                  )
                else ...<Widget>[
                  Text(s.inbType,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: NovaSpace.sm),
                  for (final _InbPreset p in _inbPresetOrder) ...<Widget>[
                    _presetTile(s, p),
                    const SizedBox(height: NovaSpace.sm),
                  ],
                ],
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: s.inbPort,
                    hintText: '8443',
                    errorText: _portError,
                  ),
                  onChanged: (String _) {
                    if (_portError != null) {
                      setState(() => _portError = null);
                    }
                  },
                ),
                if (spec.needsSni) ...<Widget>[
                  const SizedBox(height: NovaSpace.md),
                  TextField(
                    controller: _sni,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: spec.sniBorrow ? s.inbSniBorrow : s.inbSniReal,
                      hintText: 'www.example.com',
                    ),
                  ),
                  if (spec.sniBorrow) ...<Widget>[
                    const SizedBox(height: NovaSpace.sm),
                    Text(s.inbSniSuggest,
                        style: text.bodySmall?.copyWith(color: nova.muted)),
                    const SizedBox(height: NovaSpace.sm),
                    Wrap(
                      spacing: NovaSpace.sm,
                      runSpacing: NovaSpace.sm,
                      children: <Widget>[
                        for (final String d in _sniSuggestions)
                          NovaPill(
                            label: d,
                            selected: _sni.text.trim() == d,
                            onTap: () => setState(() => _sni.text = d),
                          ),
                      ],
                    ),
                  ],
                ],
                if (spec.needsServiceName) ...<Widget>[
                  const SizedBox(height: NovaSpace.md),
                  TextField(
                    controller: _serviceName,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: s.inbServiceName,
                      hintText: 'grpc',
                    ),
                  ),
                ],
                if (spec.needsPath) ...<Widget>[
                  const SizedBox(height: NovaSpace.md),
                  TextField(
                    controller: _path,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    decoration: InputDecoration(
                      labelText: s.inbPath,
                      hintText: '/nova',
                    ),
                  ),
                ],
                if (spec.needsMode) ...<Widget>[
                  const SizedBox(height: NovaSpace.md),
                  Row(
                    children: <Widget>[
                      Expanded(child: Text(s.inbMode)),
                      DropdownButton<String>(
                        value: _xhttpMode,
                        items: _xhttpModes
                            .map((String o) => DropdownMenuItem<String>(
                                value: o, child: Text(o)))
                            .toList(),
                        onChanged: (String? v) {
                          if (v != null) setState(() => _xhttpMode = v);
                        },
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: NovaSpace.md),
                TextField(
                  controller: _remark,
                  decoration: InputDecoration(labelText: s.inbRemark),
                ),
                if (spec.reality || spec.method != null) ...<Widget>[
                  const SizedBox(height: NovaSpace.md),
                  Text(
                    spec.reality ? s.inbKeysAutoNote : s.inbSsAutoNote,
                    style: text.bodySmall?.copyWith(color: nova.muted),
                  ),
                ],
                const SizedBox(height: NovaSpace.lg),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: NovaButton(
                        label: s.vpsCancel,
                        variant: NovaButtonVariant.secondary,
                        expand: true,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: NovaSpace.md),
                    Expanded(
                      child: NovaButton(
                        label: s.vpsSave,
                        icon: Icons.check_rounded,
                        expand: true,
                        onPressed: _save,
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

  Widget _presetTile(NovaStrings s, _InbPreset p) {
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final bool selected = p == _preset;
    final bool recommended = p == _InbPreset.realityVision;
    return NovaCard(
      raised: selected,
      borderColor: selected ? nova.cyan.withValues(alpha: 0.55) : null,
      padding: const EdgeInsets.all(NovaSpace.md),
      onTap: () => _onPreset(p),
      child: Row(
        children: <Widget>[
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 20,
            color: selected ? nova.cyan : nova.muted,
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        _presetTitle(s, p),
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (recommended) ...<Widget>[
                      const SizedBox(width: NovaSpace.sm),
                      NovaPill(label: s.inbRecommended, selected: true),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _presetSub(s, p),
                  style: text.bodySmall?.copyWith(color: nova.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
