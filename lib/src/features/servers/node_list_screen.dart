import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/singbox/node_probe.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../../core/proxy/subscription.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_scope.dart';

/// Lists the nodes of a subscription with a live TCP latency for each, and lets
/// the user pin a specific exit (or fall back to auto-select). Pinning updates
/// the profile and reconnects through the chosen node — this is the "switch to
/// a better IP" control.
class NodeListScreen extends StatefulWidget {
  const NodeListScreen({super.key, required this.profileId});

  final String profileId;

  @override
  State<NodeListScreen> createState() => _NodeListScreenState();
}

class _NodeListScreenState extends State<NodeListScreen> {
  /// Cap how many nodes we display + ping, so a 1000-node subscription stays
  /// responsive. They're deduped by server:port first.
  static const int _maxShown = 80;

  List<ProxyNode> _nodes = <ProxyNode>[];
  final Map<String, int> _ping = <String, int>{}; // key -> ms (-1 = unreachable)
  final Map<String, String> _cc = <String, String>{}; // key -> ISO country code
  final Map<String, String> _ccByIp = <String, String>{}; // ip -> cc cache
  final Map<String, String> _place = <String, String>{}; // key -> "Country · City"
  final Map<String, String> _placeByIp = <String, String>{}; // ip -> place cache
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _loading = true;
  String? _error;

  // Include protocol + ws path so one host offered over several protocols
  // (VLESS / VMess / Trojan on the same :443, different paths) shows as
  // distinct selectable nodes instead of collapsing to one. Matches the
  // tunnel's own de-dupe key (server:port:wsPath).
  String _key(ProxyNode n) =>
      '${n.server}:${n.port}:${n.protocol.name}:${n.wsPath ?? ''}';

  @override
  void initState() {
    super.initState();
    // Defer to after the first frame: _load() reads NovaScope.of(context),
    // which can't be looked up while initState is still running.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _http.close(force: true);
    _search.dispose();
    super.dispose();
  }

  /// True when the node matches the current search text. Matches on the display
  /// name, protocol, address and resolved location so any of them can be typed.
  bool _matches(ProxyNode n) {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final String hay = <String>[
      n.tag,
      n.protocol.label,
      '${n.server}:${n.port}',
      _place[_key(n)] ?? '',
      n.sni ?? '',
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  ProxyProfile? get _profile {
    final list = NovaScope.of(context).profiles.profiles;
    for (final p in list) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  Future<void> _load() async {
    final profiles = NovaScope.of(context).profiles;
    final profile = _profile;
    if (profile == null) {
      setState(() {
        _loading = false;
        _error = 'Profile not found';
      });
      return;
    }
    try {
      final all = await resolveProfileNodes(profile);
      // Dedupe by server:port and cap.
      final seen = <String>{};
      final deduped = <ProxyNode>[];
      for (final n in all) {
        if (seen.add(_key(n))) deduped.add(n);
        if (deduped.length >= _maxShown) break;
      }
      // Keep the real node count on the profile so the cards stop saying "1".
      profiles.update(profile.copyWith(nodeCount: all.length));
      if (!mounted) return;
      setState(() {
        _nodes = deduped;
        _loading = false;
      });
      _pingAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load nodes: $e';
      });
    }
  }

  Future<void> _pingAll() async {
    // Bounded concurrency so we don't open 80 sockets at once.
    const int batch = 12;
    for (int i = 0; i < _nodes.length; i += batch) {
      final slice = _nodes.skip(i).take(batch);
      await Future.wait(slice.map(_pingOne));
      if (!mounted) return;
      setState(() {});
    }
    _saveFastNodes();
  }

  /// Persist the fastest reachable nodes so Auto-select builds its urltest pool
  /// from these instead of the subscription's arbitrary first few.
  void _saveFastNodes() {
    final profile = _profile;
    if (profile == null) return;
    final reachable = _nodes
        .map(_key)
        .where((k) => (_ping[k] ?? -1) >= 0)
        .toList()
      ..sort((a, b) => _ping[a]!.compareTo(_ping[b]!));
    if (reachable.isEmpty) return;
    NovaScope.of(context)
        .profiles
        .update(profile.copyWith(fastNodes: reachable.take(24).toList()));
  }

  Future<void> _pingOne(ProxyNode n) async {
    // Full TLS-handshake probe, not a bare TCP connect: Cloudflare's edge
    // accepts any TCP handshake, so a plain connect showed every node green
    // even on networks where the SNI is DPI-blocked and nothing would work.
    _ping[_key(n)] = await probeNodeMs(n) ?? -1;
    await _geoOne(n);
  }

  /// Geo-locate a node's host so the row can show a country flag. Cached per IP
  /// (many nodes share Cloudflare IPs), best-effort over HTTPS.
  Future<void> _geoOne(ProxyNode n) async {
    final String host = n.server;
    if (_ccByIp.containsKey(host)) {
      _cc[_key(n)] = _ccByIp[host]!;
      if ((_placeByIp[host] ?? '').isNotEmpty) _place[_key(n)] = _placeByIp[host]!;
      return;
    }
    try {
      final req = await _http.getUrl(Uri.parse('https://ipwho.is/$host'));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final cc = (j['country_code'] as String?)?.toUpperCase() ?? '';
      final country = (j['country'] as String?) ?? '';
      final city = (j['city'] as String?) ?? '';
      // Lead with the city (the distinguishing part; the flag already shows the
      // country), kept short with the country code. Fall back to country name.
      final String place = city.isNotEmpty
          ? (cc.isNotEmpty ? '$city, $cc' : city)
          : country;
      _ccByIp[host] = cc;
      _placeByIp[host] = place;
      if (cc.isNotEmpty) _cc[_key(n)] = cc;
      if (place.isNotEmpty) _place[_key(n)] = place;
    } catch (_) {/* leave flag blank */}
  }

  Future<void> _pin(String? key) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null) return;
    final updated = profile.copyWith(pinnedNode: key);
    scope.profiles.update(updated);
    scope.profiles.setActive(updated.id);
    scope.proxy.selectProfile(updated);
    if (mounted) setState(() {});
    // Hot-swap: if the tunnel is up, restart it through the new exit in one
    // step so the user stays connected instead of having to tap connect again.
    await scope.proxy.reconnect();
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final profile = _profile;
    final sorted = <ProxyNode>[..._nodes]..sort((a, b) {
        final pa = _ping[_key(a)] ?? 9999;
        final pb = _ping[_key(b)] ?? 9999;
        final na = pa < 0 ? 100000 : pa;
        final nb = pb < 0 ? 100000 : pb;
        return na.compareTo(nb);
      });
    final visible = sorted.where(_matches).toList();
    final pinned = profile?.pinnedNode;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.name ?? 'Nodes'),
        actions: <Widget>[
          if (!_loading)
            IconButton(
              tooltip: s.nodeRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: () {
                clearSubscriptionCache();
                _ping.clear();
                setState(() => _loading = true);
                _load();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  children: <Widget>[
                    const _FreeBanner(),
                    const _SocialRow(),
                    const Divider(height: 1),
                    _AutoRow(
                      selected: pinned == null,
                      onTap: () => _pin(null),
                    ),
                    const Divider(height: 1),
                    if (_nodes.length > 6) _searchField(s),
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 40),
                        child: Center(
                          child: Text(s.nodeNoMatch,
                              style: TextStyle(color: context.nova.muted)),
                        ),
                      )
                    else
                      for (final n in visible)
                        _NodeRow(
                          node: n,
                          ms: _ping[_key(n)],
                          countryCode: _cc[_key(n)],
                          place: _place[_key(n)],
                          selected: pinned == _key(n),
                          onTap: () => _pin(_key(n)),
                        ),
                  ],
                ),
    );
  }

  Widget _searchField(NovaStrings s) {
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: s.nodeSearch,
          prefixIcon: Icon(Icons.search, color: nova.muted, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close, color: nova.muted, size: 18),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: nova.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: nova.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: nova.border),
          ),
        ),
      ),
    );
  }
}

/// Anti-resale banner: Nova is free, so anyone who was sold these configs sees
/// they should never have paid. Shown at the top of every node list.
class _FreeBanner extends StatelessWidget {
  const _FreeBanner();

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: <Color>[
            nova.cyan.withValues(alpha: 0.16),
            nova.violet.withValues(alpha: 0.16),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: nova.cyan.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: nova.cyan.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.volunteer_activism_rounded,
                color: nova.cyan, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.nodeFreeTitle,
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(s.nodeFreeBody,
                    style: text.bodySmall?.copyWith(color: nova.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Nova's official channels. Same links as Settings, surfaced here so users
/// find the real community (and don't chase a reseller's fake one).
class _SocialRow extends StatelessWidget {
  const _SocialRow();

  static const List<(IconData, String)> _links = <(IconData, String)>[
    (Icons.send_rounded, 'https://t.me/irnova_proxy'),
    (Icons.camera_alt_rounded, 'https://instagram.com/irnova_proxy'),
    (Icons.code_rounded, 'https://github.com/IRNova'),
    (Icons.language_rounded, 'https://novaproxy.online/'),
  ];

  Future<void> _open(String url) async {
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          Text(s.nodeCommunity,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: nova.muted, fontWeight: FontWeight.w600)),
          const Spacer(),
          for (final (IconData icon, String url) in _links)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _open(url),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: nova.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: nova.border),
                  ),
                  child: Icon(icon, color: nova.cyan, size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final Color accent = context.nova.indigo;
    return ListTile(
      leading: Icon(Icons.bolt, color: accent),
      title: Text(s.nodeAuto),
      subtitle: Text(s.nodeAutoSub),
      trailing: selected ? Icon(Icons.check_circle, color: accent) : null,
      onTap: onTap,
    );
  }
}

/// ISO 3166 alpha-2 country code → flag emoji (regional indicator symbols).
String _flagEmoji(String cc) {
  if (cc.length != 2) return '🏳️';
  const int base = 0x1F1E6;
  final int a = cc.codeUnitAt(0) - 0x41;
  final int b = cc.codeUnitAt(1) - 0x41;
  if (a < 0 || a > 25 || b < 0 || b > 25) return '🏳️';
  return String.fromCharCodes(<int>[base + a, base + b]);
}

/// Strips the protocol tag and address that panels bake into a node's display
/// name (e.g. "سرویس رایگان نوا [VLESS] 1.2.3.4:2087") so the row can show a
/// clean name and render the protocol/address itself. Returns '' when nothing
/// meaningful is left (all the info was the address).
String _cleanNodeName(ProxyNode n) {
  String s = n.tag;
  s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' '); // [VLESS] etc.
  s = s.replaceAll('${n.server}:${n.port}', ' ').replaceAll(n.server, ' ');
  s = s.replaceAll(RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}:\d+\b'), ' '); // any ip:port
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[\-·•|:]+|[\-·•|:]+$'), '').trim();
  return s;
}

/// Short transport chips: how the node actually connects (WS/gRPC, TLS/Reality,
/// and UDP for the QUIC protocols that carry UDP end to end, good for calls).
List<String> _transportTags(ProxyNode n) {
  final List<String> t = <String>[];
  switch (n.network.toLowerCase()) {
    case 'ws':
      t.add('WS');
    case 'grpc':
      t.add('gRPC');
    case 'http':
      t.add('HTTP');
  }
  if ((n.realityPublicKey ?? '').isNotEmpty) {
    t.add('Reality');
  } else if (n.tls) {
    t.add('TLS');
  }
  if (n.protocol.isUdpNative) t.add('UDP');
  return t;
}

/// The deeper TLS handshake details (SNI, uTLS fingerprint, VLESS flow) shown on
/// a secondary line. Empty when the node carries none of them.
String _nodeDetail(ProxyNode n) {
  // Short, high-value bits first (uTLS, flow) so they stay visible; the long
  // SNI host goes last and truncates gracefully.
  final List<String> parts = <String>[
    if ((n.fingerprint ?? '').isNotEmpty) 'uTLS ${n.fingerprint}',
    if ((n.flow ?? '').isNotEmpty) 'flow ${n.flow}',
    if ((n.sni ?? '').isNotEmpty) 'SNI ${n.sni}',
  ];
  return parts.join('   ·   ');
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.ms,
    required this.countryCode,
    required this.place,
    required this.selected,
    required this.onTap,
  });

  final ProxyNode node;
  final int? ms;
  final String? countryCode;
  final String? place; // "Country · City" once geo resolves
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final String cc = countryCode ?? '';
    final String addr = '${node.server}:${node.port}';
    final String clean = _cleanNodeName(node);
    // Lead with the location so rows are distinguishable; fall back to the
    // (cleaned) node name, then the address, while geo is still resolving.
    final String location = place ?? '';
    final String primary =
        location.isNotEmpty ? location : (clean.isNotEmpty ? clean : addr);
    final List<String> transport = _transportTags(node);
    final String detail = _nodeDetail(node);
    return ListTile(
      isThreeLine: detail.isNotEmpty,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: cc.isNotEmpty
          ? Text(_flagEmoji(cc), style: const TextStyle(fontSize: 26))
          : Icon(Icons.public_rounded, color: nova.muted, size: 24),
      title: Row(
        children: <Widget>[
          _ProtoBadge(protocol: node.protocol),
          const SizedBox(width: 8),
          Expanded(
            child: Text(primary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 4),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              Text(addr,
                  style: text.bodySmall?.copyWith(color: nova.muted)),
              for (final String t in transport) _MiniTag(text: t),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall?.copyWith(color: nova.muted),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _PingBadge(ms: ms),
          if (selected) ...<Widget>[
            const SizedBox(width: 10),
            Icon(Icons.check_circle, color: nova.indigo, size: 20),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A small colored pill naming the node's protocol (VLESS, VMess, …), so it is
/// always readable instead of being truncated inside the name.
class _ProtoBadge extends StatelessWidget {
  const _ProtoBadge({required this.protocol});
  final NodeProtocol protocol;

  Color _color(NovaColors nova) => switch (protocol) {
        NodeProtocol.vless => nova.cyan,
        NodeProtocol.vmess => nova.violet,
        NodeProtocol.trojan => nova.indigo,
        NodeProtocol.shadowsocks => nova.info,
        NodeProtocol.hysteria2 => nova.cyan,
        NodeProtocol.tuic => nova.violet,
        NodeProtocol.awg => nova.success,
      };

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color c = _color(nova);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Text(
        protocol.label.toUpperCase(),
        style: TextStyle(
            color: c, fontWeight: FontWeight.w700, fontSize: 11, height: 1.1),
      ),
    );
  }
}

/// A muted outline chip for a transport detail (WS, TLS, Reality, …).
class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: nova.border),
      ),
      child: Text(text,
          style: TextStyle(
              color: nova.muted, fontWeight: FontWeight.w600, fontSize: 10)),
    );
  }
}

class _PingBadge extends StatelessWidget {
  const _PingBadge({required this.ms});
  final int? ms;

  @override
  Widget build(BuildContext context) {
    if (ms == null) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (ms! < 0) {
      return Text('timeout',
          style: TextStyle(color: NovaSemantics.red, fontSize: 12));
    }
    return Text('$ms ms',
        style: TextStyle(
            color: NovaSemantics.ping(ms), fontWeight: FontWeight.w600));
  }
}
