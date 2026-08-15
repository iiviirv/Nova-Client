import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/nova_log.dart';
import '../../core/models/proxy_profile.dart';
import '../../core/proxy/singbox/node_probe.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../../core/proxy/subscription.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_colors.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_semantics.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_components.dart';
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

  /// key -> what the probe could actually prove about the node.
  final Map<String, NodeProbeResult> _probe = <String, NodeProbeResult>{};

  /// key -> where the node really is, when that is knowable at all.
  final Map<String, _Geo> _geo = <String, _Geo>{};

  /// host -> resolved geo, so the many nodes sharing one address (a panel hands
  /// out the same clean IP for every protocol) cost one lookup.
  final Map<String, _Geo> _geoByHost = <String, _Geo>{};

  /// What the subscription carried that Nova cannot run, so the list can say
  /// why it is shorter than the panel's own count.
  SkippedLinks _skipped = SkippedLinks(<String, int>{});
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
  String _key(ProxyNode n) => proxyNodeKey(n);

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
      _geo[_key(n)]?.place ?? '',
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
      // Whatever the subscription carried that Nova cannot run. Captured right
      // after the parse, before anything else can overwrite the side channel.
      _skipped = lastSkippedLinks;
      if (!_skipped.isEmpty) {
        NovaLog.instance.write(
          'Subscription had ${_skipped.total} entries Nova cannot run: '
          '${_skipped.byScheme.entries.map((MapEntry<String, int> e) => '${e.key} x${e.value}').join(', ')}',
          level: NovaLogLevel.warn,
        );
      }
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
    _logSummary();
    _saveFastNodes();
  }

  /// One line in the app log for the whole sweep. Per-node lines would drown
  /// everything else for an 80-node subscription, but the shape of the result
  /// is exactly what a support conversation needs: "all blocked" and "all
  /// answered but none proven" are different problems with different answers.
  void _logSummary() {
    final Map<NodeProbeQuality, int> tally = <NodeProbeQuality, int>{};
    for (final ProxyNode n in _nodes) {
      final NodeProbeResult? r = _probe[_key(n)];
      if (r == null) continue;
      tally[r.quality] = (tally[r.quality] ?? 0) + 1;
    }
    NovaLog.instance.write(
      'Tested ${_nodes.length} servers: '
      '${tally[NodeProbeQuality.proxied] ?? 0} carried a test request, '
      '${tally[NodeProbeQuality.handshake] ?? 0} answered, '
      '${tally[NodeProbeQuality.unreachable] ?? 0} blocked, '
      '${tally[NodeProbeQuality.untestable] ?? 0} not testable',
    );
  }

  /// Persist the nodes a probe actually proved, fastest first, so Auto-select
  /// builds its urltest pool from these instead of the subscription's arbitrary
  /// first few. Nodes that only completed a TCP or TLS handshake are no longer
  /// eligible: seeding the pool with them is what put dead exits at the front.
  void _saveFastNodes() {
    final profile = _profile;
    if (profile == null) return;
    final proven = _nodes
        .map(_key)
        .where((k) => _probe[k]?.ok ?? false)
        .toList()
      ..sort((a, b) => _probe[a]!.sortKey.compareTo(_probe[b]!.sortKey));
    if (proven.isEmpty) return;
    NovaScope.of(context).profiles.update(profile.copyWith(
          lastLatencyMs: _probe[proven.first]!.latencyMs,
          fastNodes: proven.take(24).toList(),
        ));
  }

  Future<void> _pingOne(ProxyNode n) async {
    // A real end-to-end test, not a bare TCP connect: Cloudflare's edge accepts
    // any TCP handshake, so a plain connect showed every node green even on
    // networks where nothing would ever get through. See node_probe.dart for
    // what each tier proves.
    _probe[_key(n)] = await probeNode(n);
    await _geoOne(n);
  }

  /// Works out where a node really is, when that is knowable at all.
  ///
  /// The address a panel hands out is frequently a Cloudflare clean IP, which
  /// belongs to an anycast edge and is announced from wherever the user happens
  /// to be. Geo-locating it produced a confident, wrong country for nodes whose
  /// real exit is somewhere else entirely. Those are reported as fronted instead
  /// of guessed at. A domain is resolved first so real servers behind a hostname
  /// get a flag too, which they never used to.
  Future<void> _geoOne(ProxyNode n) async {
    final String host = n.server;
    final _Geo? cached = _geoByHost[host];
    if (cached != null) {
      _geo[_key(n)] = cached;
      return;
    }
    try {
      final String target = await _resolveHost(host);
      final req = await _http.getUrl(Uri.parse('https://ipwho.is/$target'));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['success'] == false) return;
      final connection = (j['connection'] as Map<String, dynamic>?) ?? const {};
      final String network = <String>[
        (connection['org'] as String?) ?? '',
        (connection['isp'] as String?) ?? '',
      ].join(' ');
      final String? front = _cdnName(network, (connection['asn'] as num?)?.toInt());
      final _Geo g;
      if (front != null) {
        g = _Geo.fronted(front);
      } else {
        final cc = (j['country_code'] as String?)?.toUpperCase() ?? '';
        final country = (j['country'] as String?) ?? '';
        final city = (j['city'] as String?) ?? '';
        // Lead with the city (the distinguishing part; the flag already shows
        // the country), kept short with the country code. Fall back to country.
        final String place =
            city.isNotEmpty ? (cc.isNotEmpty ? '$city, $cc' : city) : country;
        g = _Geo(countryCode: cc, place: place);
      }
      _geoByHost[host] = g;
      _geo[_key(n)] = g;
    } catch (_) {/* leave the row on its name */}
  }

  /// The address to look up: an IP literal as-is, a hostname resolved first.
  Future<String> _resolveHost(String host) async {
    if (InternetAddress.tryParse(host) != null) return host;
    try {
      final List<InternetAddress> found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      if (found.isNotEmpty) return found.first.address;
    } catch (_) {
      // Fall through: ipwho.is resolves hostnames itself, so the raw host is
      // still a usable query when the device cannot resolve it.
    }
    return host;
  }

  Future<void> _pin(String? key) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null) return;
    NovaLog.instance.write(
        key == null ? 'You chose Auto' : 'You chose the server $key');
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
    // Proven nodes first, then fastest. A node still being measured keeps its
    // place until its verdict lands, so rows don't jump while the list fills in.
    final sorted = <ProxyNode>[..._nodes]..sort((a, b) {
        final int ka = _probe[_key(a)]?.sortKey ?? 1500000;
        final int kb = _probe[_key(b)]?.sortKey ?? 1500000;
        return ka.compareTo(kb);
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
                _probe.clear();
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
              : _list(s, visible, pinned),
    );
  }

  /// The header blocks are a handful of cheap widgets; the node rows are built
  /// on demand so an 80-node subscription only lays out what is on screen.
  Widget _list(NovaStrings s, List<ProxyNode> visible, String? pinned) {
    final List<Widget> header = <Widget>[
      const _FreeBanner(),
      if (!_skipped.isEmpty) _SkippedNote(skipped: _skipped),
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
              horizontal: NovaSpace.lg, vertical: 40),
          child: Center(
            child: Text(s.nodeNoMatch,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.nova.muted)),
          ),
        ),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: NovaSpace.xl),
      itemCount: header.length + visible.length,
      itemBuilder: (BuildContext context, int i) {
        if (i < header.length) return header[i];
        final int r = i - header.length;
        final ProxyNode n = visible[r];
        return _NodeRow(
          node: n,
          probe: _probe[_key(n)],
          geo: _geo[_key(n)],
          selected: pinned == _key(n),
          showDivider: r < visible.length - 1,
          onTap: () => _pin(_key(n)),
        );
      },
    );
  }

  Widget _searchField(NovaStrings s) {
    final nova = context.nova;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xs),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: s.nodeSearch,
          prefixIcon: Icon(Icons.search, color: nova.muted, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: s.nodeClearSearch,
                  icon: Icon(Icons.close, color: nova.muted, size: 18),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: nova.surface,
          border: OutlineInputBorder(
            borderRadius: NovaRadii.tabR,
            borderSide: BorderSide(color: nova.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: NovaRadii.tabR,
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
      margin: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.lg, NovaSpace.lg, NovaSpace.sm),
      padding: const EdgeInsets.all(NovaSpace.md + 2),
      decoration: BoxDecoration(
        borderRadius: NovaRadii.cardR,
        gradient: LinearGradient(
          colors: <Color>[
            nova.cyan.withValues(alpha: 0.12),
            nova.violet.withValues(alpha: 0.12),
          ],
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
        ),
        border: Border.all(color: nova.cyan.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          NovaIconChip(
            icon: Icons.volunteer_activism_rounded,
            color: nova.cyan,
            size: 36,
            radius: 10,
            iconScale: 0.56,
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.nodeFreeTitle,
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
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

/// Names what the subscription carried that Nova cannot run.
///
/// Without this the list is simply shorter than the panel says it should be,
/// and the user has no way to tell a server Nova skipped from one the operator
/// never created. Deliberately muted rather than alarming: nothing is broken,
/// there is just less here than the server offered.
class _SkippedNote extends StatelessWidget {
  const _SkippedNote({required this.skipped});

  final SkippedLinks skipped;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    // Two names is enough to be actionable; a long tail would push the real
    // list off the screen.
    final List<String> shown = skipped.schemes.take(2).toList();
    final String names = shown.join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.xs, NovaSpace.lg, NovaSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(
                start: NovaSpace.sm, top: 1),
            child:
                Icon(Icons.info_outline_rounded, size: 16, color: nova.muted),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(
              s.nodeSkipped(skipped.total, names),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: nova.muted),
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

  static const List<(IconData, String, String)> _links =
      <(IconData, String, String)>[
    (Icons.send_rounded, 'Telegram', 'https://t.me/irnova_proxy'),
    (Icons.camera_alt_rounded, 'Instagram', 'https://instagram.com/irnova_proxy'),
    (Icons.code_rounded, 'GitHub', 'https://github.com/IRNova'),
    (Icons.language_rounded, 'novaproxy.online', 'https://novaproxy.online/'),
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
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.xs, NovaSpace.lg, NovaSpace.md),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(s.nodeCommunity,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: nova.muted, fontWeight: FontWeight.w600)),
          ),
          for (final (IconData icon, String name, String url) in _links)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: NovaSpace.xs),
              child: Tooltip(
                message: name,
                child: Material(
                  color: nova.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: NovaRadii.smR,
                    side: BorderSide(color: nova.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _open(url),
                    child: SizedBox(
                      // A 40dp target: the icons are 18dp and used to sit in a
                      // 34dp box, under the minimum touch size.
                      width: 40,
                      height: 40,
                      child: Icon(icon, color: nova.cyan, size: 18),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The Auto row: the default, and the way back to it after pinning a node.
/// Styled like a node row so it reads as the first choice in the same list.
class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    final Color accent = nova.indigo;
    return Material(
      color: selected ? accent.withValues(alpha: 0.07) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          selected: selected,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: NovaSpace.lg, vertical: NovaSpace.md),
            child: Row(
              children: <Widget>[
                NovaIconChip(
                    icon: Icons.bolt_rounded, color: accent, size: 36, radius: 10),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(s.nodeAuto,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(s.nodeAutoSub,
                          style: text.bodySmall?.copyWith(color: nova.muted)),
                    ],
                  ),
                ),
                if (selected) ...<Widget>[
                  const SizedBox(width: NovaSpace.sm),
                  Icon(Icons.check_circle_rounded, color: accent, size: 22),
                ],
              ],
            ),
          ),
        ),
      ),
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
  s = s.replaceAll(
      RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}:\d+\b'), ' '); // any ip:port
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
List<String> _nodeDetail(ProxyNode n) {
  // Short, high-value bits first (uTLS, flow) so they stay visible; the long
  // SNI host goes last and wraps onto its own line if it must.
  return <String>[
    if ((n.fingerprint ?? '').isNotEmpty) 'uTLS ${n.fingerprint}',
    if ((n.flow ?? '').isNotEmpty) 'flow ${n.flow}',
    if ((n.sni ?? '').isNotEmpty) 'SNI ${n.sni}',
  ];
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.probe,
    required this.geo,
    required this.selected,
    required this.onTap,
    this.showDivider = true,
  });

  final ProxyNode node;

  /// Null while the node is still being measured.
  final NodeProbeResult? probe;

  /// Null until the location resolves, and location-free for fronted addresses.
  final _Geo? geo;
  final bool selected;
  final VoidCallback onTap;

  /// Hairline under the row; off for the last row so the list ends clean.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final String cc = geo?.countryCode ?? '';
    final String addr = '${node.server}:${node.port}';
    final String clean = _cleanNodeName(node);
    // Lead with a real location when there is one. A fronted address has no
    // location to show, so the row falls back to the name the panel gave it
    // rather than printing the CDN edge's country as if it were the exit.
    final String location = geo?.place ?? '';
    final String primary =
        location.isNotEmpty ? location : (clean.isNotEmpty ? clean : addr);
    final List<String> transport = <String>[
      ..._transportTags(node),
      if (geo?.frontedBy != null) geo!.frontedBy!,
    ];
    // The probe's own verdict is the most useful thing on the row when it is
    // anything other than a plain number, so it leads the detail line.
    final List<String> detail = <String>[
      if ((probe?.reason ?? '').isNotEmpty) probe!.reason!,
      ..._nodeDetail(node),
    ];

    return Material(
      color: selected ? nova.indigo.withValues(alpha: 0.07) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          selected: selected,
          child: Container(
            decoration: showDivider
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: nova.border)))
                : null,
            padding: const EdgeInsets.symmetric(
                horizontal: NovaSpace.lg, vertical: NovaSpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 30,
                  child: cc.isNotEmpty
                      ? Text(_flagEmoji(cc),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 22))
                      : Icon(Icons.public_rounded,
                          color: nova.muted, size: 22),
                ),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          _ProtoBadge(protocol: node.protocol),
                          const SizedBox(width: NovaSpace.sm),
                          Expanded(
                            child: Text(primary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: NovaSpace.xs),
                      // The address stays LTR even in Farsi: a mirrored
                      // host:port is unreadable.
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: <Widget>[
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(addr,
                                style: text.bodySmall
                                    ?.copyWith(color: nova.muted)),
                          ),
                          for (final String t in transport) _MiniTag(text: t),
                        ],
                      ),
                      if (detail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 3),
                        // One line, each part truncating on its own, so a
                        // long SNI host never pushes the row to five lines.
                        Row(
                          children: <Widget>[
                            for (int i = 0; i < detail.length; i++) ...<Widget>[
                              if (i > 0) const SizedBox(width: NovaSpace.md),
                              Flexible(
                                child: Text(detail[i],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelSmall
                                        ?.copyWith(color: nova.muted)),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: NovaSpace.md),
                _Verdict(probe: probe),
                if (selected) ...<Widget>[
                  const SizedBox(width: NovaSpace.sm),
                  Icon(Icons.check_circle_rounded,
                      color: nova.indigo, size: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small colored pill naming the node's protocol (VLESS, VMess, ...), so it
/// is always readable instead of being truncated inside the name.
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
        NodeProtocol.socks => nova.muted,
        NodeProtocol.http => nova.muted,
        NodeProtocol.naive => nova.info,
      };

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color c = _color(nova);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        protocol.label.toUpperCase(),
        style: TextStyle(
            color: c,
            fontWeight: FontWeight.w800,
            fontSize: 10,
            height: 1.2,
            letterSpacing: 0.4),
      ),
    );
  }
}

/// A quiet surface tag for a transport detail (WS, TLS, Reality, a CDN name).
/// Filled, not outlined: outlines on a dozen tiny chips read as noise.
class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: nova.surface2,
      ),
      child: Text(text,
          style: TextStyle(
              color: nova.muted,
              fontWeight: FontWeight.w600,
              fontSize: 10,
              height: 1.2)),
    );
  }
}

/// The measured verdict for a node, and the most legible thing on the row.
///
/// A number appears only when something was actually proven, and it says which:
/// a node whose traffic reached the internet gets the verified mark on a tinted
/// pill, one that only answered its own handshake gets the plain number, and one
/// that cannot be judged from outside a tunnel says so instead of borrowing a
/// number it did not earn. Blocked is a word on a red tint, never colour alone.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.probe});
  final NodeProbeResult? probe;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final NodeProbeResult? p = probe;
    if (p == null) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    switch (p.quality) {
      case NodeProbeQuality.unreachable:
        return _VerdictPill(
          label: s.nodeBlocked,
          color: NovaSemantics.red,
          filled: true,
        );
      case NodeProbeQuality.untestable:
        return _VerdictPill(label: s.nodeUntested, color: nova.muted);
      case NodeProbeQuality.proxied:
      case NodeProbeQuality.handshake:
        final int ms = p.latencyMs ?? 0;
        final Color c = NovaSemantics.ping(ms);
        final bool proven = p.quality == NodeProbeQuality.proxied;
        return _VerdictPill(
          label: '$ms ms',
          color: c,
          icon: proven ? Icons.verified_rounded : null,
          filled: proven,
          style: text.labelMedium?.copyWith(
            color: c,
            fontWeight: proven ? FontWeight.w700 : FontWeight.w600,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        );
    }
  }
}

class _VerdictPill extends StatelessWidget {
  const _VerdictPill({
    required this.label,
    required this.color,
    this.icon,
    this.filled = false,
    this.style,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool filled;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = style ??
        Theme.of(context).textTheme.labelMedium!.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            );
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: filled ? NovaSpace.sm : 0, vertical: 4),
      decoration: filled
          ? BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: NovaRadii.iconChipR,
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          // "14 ms" is a Latin run; a lone Farsi word is unaffected by LTR.
          Text(label, style: base, textDirection: TextDirection.ltr),
        ],
      ),
    );
  }
}
/// Where a node is, or why that cannot be said.
class _Geo {
  const _Geo({this.countryCode = '', this.place = ''}) : frontedBy = null;

  /// An address that belongs to a CDN's anycast edge. The country such an
  /// address resolves to is the edge the *lookup* landed on, not where the
  /// node's traffic comes out, so no location is claimed at all.
  const _Geo.fronted(String cdn)
      : countryCode = '',
        place = '',
        frontedBy = cdn;

  final String countryCode;
  final String place;
  final String? frontedBy;
}

/// Names the CDN an address belongs to, or null for an ordinary host.
///
/// Matching on the network's name as well as its number keeps this working as
/// providers add ranges: Cloudflare alone announces from several ASNs, and a
/// panel's "clean IP" is by definition one of those the operator just found.
String? _cdnName(String network, int? asn) {
  final String n = network.toLowerCase();
  if (n.contains('cloudflare') || asn == 13335 || asn == 209242) {
    return 'Cloudflare';
  }
  if (n.contains('fastly') || asn == 54113) return 'Fastly';
  if (n.contains('akamai') || asn == 20940 || asn == 16625) return 'Akamai';
  if (n.contains('cloudfront')) return 'CloudFront';
  return null;
}
