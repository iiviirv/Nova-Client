import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/nova_log.dart';
import '../../core/models/proxy_profile.dart';
import '../../core/proxy/proxy_controller.dart';
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
import 'bypass_editor_screen.dart';

/// Lists the nodes of a subscription with a live TCP latency for each, and lets
/// the user pin a specific exit (or fall back to auto-select). Pinning updates
/// the profile and reconnects through the chosen node. This is the "switch to
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

  /// True right after this screen turned the SNI-block bypass on because every
  /// server read as blocked, so the note explaining that stays visible.
  bool _bypassSuggested = false;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _loading = true;
  String? _error;

  /// The list on screen came from the saved subscription body because the live
  /// refresh could not reach the panel (its domain is blocked). The servers are
  /// still usable; the note just explains why the list may be a little old.
  bool _stale = false;

  /// A live refresh is in flight (the list may already be showing cached servers
  /// underneath). Drives the small spinner on the refresh button.
  bool _refreshing = false;

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
    final profile = _profile;
    if (profile == null) {
      setState(() {
        _loading = false;
        _error = 'Profile not found';
      });
      return;
    }
    // Show whatever is already saved, instantly. A filtered subscription URL
    // takes tens of seconds to time out, and blocking the list on that is what
    // left the user staring at a spinner. The saved servers still work, so put
    // them up now and refresh live in the background.
    final List<ProxyNode> cached = await cachedProfileNodes(profile);
    if (cached.isNotEmpty && mounted) {
      _applyNodes(cached, profile, stale: false);
    }
    await _refresh(profile, hadCache: cached.isNotEmpty);
  }

  /// Fetches the subscription live and updates the list, keeping whatever is on
  /// screen if the fetch fails. Shared by the initial load and the manual
  /// refresh button. [hadCache] means the list is already populated, so a
  /// failure is a soft "stale" note rather than a fatal error.
  Future<void> _refresh(ProxyProfile profile,
      {required bool hadCache, bool forcePing = false}) async {
    if (mounted) setState(() => _refreshing = true);
    try {
      final List<ProxyNode> all = await resolveProfileNodes(profile);
      if (!mounted) return;
      _applyNodes(all, profile, stale: lastResolveWasStale, forcePing: forcePing);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        // Never wipe a list the user already has over a failed refresh. The hard
        // error is only for the genuine first-run case with nothing saved yet.
        if (_nodes.isNotEmpty || hadCache) {
          _stale = true;
        } else {
          _error = 'Could not load nodes: $e';
        }
      });
    }
  }

  /// Applies a resolved node list to the screen: dedupe + cap, record skipped
  /// entries and the real count, and (re)ping only when the set actually changed
  /// so a background refresh that returns the same servers doesn't re-probe.
  void _applyNodes(List<ProxyNode> all, ProxyProfile profile,
      {required bool stale, bool forcePing = false}) {
    final profiles = NovaScope.of(context).profiles;
    _stale = stale;
    // Captured right after the parse, before anything else overwrites the side
    // channel. A background refresh with an empty result (all cached) leaves the
    // previous skipped tally untouched.
    if (all.isNotEmpty) _skipped = lastSkippedLinks;
    if (!_skipped.isEmpty) {
      NovaLog.instance.write(
        'Subscription had ${_skipped.total} entries Nova cannot run: '
        '${_skipped.byScheme.entries.map((MapEntry<String, int> e) => '${e.key} x${e.value}').join(', ')}',
        level: NovaLogLevel.warn,
      );
    }
    final Set<String> seen = <String>{};
    final List<ProxyNode> deduped = <ProxyNode>[];
    for (final ProxyNode n in all) {
      if (seen.add(_key(n))) deduped.add(n);
      if (deduped.length >= _maxShown) break;
    }
    final bool changed = !_sameKeys(deduped, _nodes);
    // Keep the real node count on the profile so the cards stop saying "1".
    profiles.update(profile.copyWith(nodeCount: all.length));
    setState(() {
      _nodes = deduped;
      _loading = false;
      _refreshing = false;
    });
    if (changed || forcePing) _pingAll();
  }

  /// The refresh button: re-fetch the subscription now, re-probe, and if this
  /// profile is the live tunnel, reconnect so the freshest list's best node is
  /// the one carrying traffic. Keeps the servers on screen the whole time.
  Future<void> _manualRefresh() async {
    final ProxyProfile? profile = _profile;
    if (profile == null || _refreshing) return;
    clearSubscriptionCache();
    _probe.clear();
    await _refresh(profile, hadCache: _nodes.isNotEmpty, forcePing: true);
    if (!mounted) return;
    final scope = NovaScope.of(context);
    if (scope.proxy.state.isActive &&
        scope.proxy.activeProfile?.id == profile.id) {
      NovaLog.instance.write('Manual refresh: reconnecting to the best server');
      await scope.proxy.reconnect();
    }
  }

  bool _sameKeys(List<ProxyNode> a, List<ProxyNode> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (_key(a[i]) != _key(b[i])) return false;
    }
    return true;
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
    _maybeSuggestBypass();
  }

  /// Every server reads as blocked, and there are clean-IP fronted servers in
  /// the list: the signature of a network that blocks the worker's SNI. Turn
  /// the SNI-block bypass on for the profile (persisted) and say so, so the
  /// next connect starts with it instead of failing the same way once more.
  /// The probe itself cannot try the bypass (it uses the platform's TLS), so
  /// the proof happens on connect; the controller escalates the same way there.
  void _maybeSuggestBypass() {
    final profile = _profile;
    if (profile == null || profile.hardenTls || _nodes.isEmpty) return;
    final bool allBlocked = _nodes.every((ProxyNode n) =>
        _probe[_key(n)]?.quality == NodeProbeQuality.unreachable);
    if (!allBlocked) return;
    if (!_nodes.any((ProxyNode n) => n.isCleanIpFronted)) return;
    NovaLog.instance.write(
      'Every server in "${profile.name}" reads as blocked; turning on the '
      'SNI-block bypass for its clean-IP servers.',
      level: NovaLogLevel.warn,
    );
    NovaScope.of(context).profiles.update(profile.copyWith(hardenTls: true));
    _bypassSuggested = true;
    if (mounted) setState(() {});
  }

  /// Turn the bypass on or off by hand. Reconnects if this profile is the live
  /// tunnel, so the change takes effect without a second tap.
  Future<void> _setBypass(bool on) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null || profile.hardenTls == on) return;
    NovaLog.instance.write(
        'You turned the SNI-block bypass ${on ? 'on' : 'off'} for "${profile.name}"');
    final updated = profile.copyWith(hardenTls: on);
    scope.profiles.update(updated);
    _bypassSuggested = false;
    if (mounted) setState(() {});
    if (scope.proxy.activeProfile?.id == profile.id) {
      scope.proxy.selectProfile(updated);
      if (scope.proxy.state.isActive) await scope.proxy.reconnect();
    }
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
    _probe[_key(n)] = await probeNode(n, bypass: _profile?.hardenTls ?? false);
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

  void _openBypassEditor() {
    final ProxyProfile? profile = _profile;
    if (profile == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BypassEditorScreen(profileId: profile.id),
      ),
    );
  }

  Future<void> _pin(String? key, {String? name}) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null) return;
    NovaLog.instance.write(
        key == null ? 'You chose Auto' : 'You chose the server $key');
    // Store the name too: if the panel later rotates this node's clean IP, the
    // key stops matching, and the name is what keeps the pin on the same server.
    final updated = profile.copyWith(pinnedNode: key, pinnedName: name);
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
    final visible = _nodes.where(_matches).toList();
    final pinned = profile?.pinnedNode;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.name ?? 'Nodes'),
        actions: <Widget>[
          if (!_loading)
            IconButton(
              tooltip: s.nodeRefresh,
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _refreshing ? null : _manualRefresh,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              // The core's live per-node latency lands while the tunnel is up;
              // rebuild the rows when it changes so the SNI-blocked servers can
              // show a real ping (and which one is carrying traffic) at last.
              : ValueListenableBuilder<CoreNodeHealth>(
                  valueListenable: NovaScope.of(context).proxy.coreHealth,
                  builder: (BuildContext context, CoreNodeHealth health, _) =>
                      _list(s, visible, pinned, health),
                ),
    );
  }

  /// The header blocks are a handful of cheap widgets; the node rows are built
  /// on demand so an 80-node subscription only lays out what is on screen.
  Widget _list(NovaStrings s, List<ProxyNode> visibleUnsorted, String? pinned,
      CoreNodeHealth health) {
    // Ranking, best first. When connected, the core's live pings win: a node the
    // core actually measured through the tunnel leads (lowest ping first), so the
    // working servers surface at the top instead of being buried under the nodes
    // the outside probe can only call "not testable". Disconnected (empty health)
    // this collapses to the old probe order. A node still being measured keeps
    // its place until its verdict lands, so rows don't jump while the list fills.
    int rank(ProxyNode n) {
      final int? live = health.delayFor(n);
      if (live != null) return live; // 0..~, measured pool nodes first by ping
      if (health.wasTested(n)) return 1000000; // tested but no response
      // Not in the live pool: fall back to the outside-probe verdict, after all
      // core-measured rows.
      return 2000000 + (_probe[_key(n)]?.sortKey ?? 500000);
    }

    final List<ProxyNode> visible = <ProxyNode>[...visibleUnsorted]
      ..sort((ProxyNode a, ProxyNode b) => rank(a).compareTo(rank(b)));
    final List<Widget> header = <Widget>[
      if (_stale) const _StaleNote(),
      if (!_skipped.isEmpty) _SkippedNote(skipped: _skipped),
      const _SocialRow(),
      const Divider(height: 1),
      _AutoRow(
        selected: pinned == null,
        onTap: () => _pin(null),
      ),
      const Divider(height: 1),
      if (_nodes.any((ProxyNode n) => n.isCleanIpFronted)) ...<Widget>[
        _BypassRow(
          on: _profile?.hardenTls ?? false,
          onChanged: _setBypass,
          onEdit: _openBypassEditor,
          note: _bypassSuggested ? s.nodeBypassAllBlocked : null,
        ),
        const Divider(height: 1),
      ],
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
          // The core's live latency for this node (through the actual tunnel, so
          // with the bypass applied), whether the core tested it at all, and
          // whether the auto-selector is currently routing through it. All
          // null/false unless connected.
          coreDelayMs: health.delayFor(n),
          coreTested: health.wasTested(n),
          active: health.isSelected(n),
          showDivider: r < visible.length - 1,
          onTap: () => _pin(_key(n), name: n.tag),
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

/// Soft note shown when the panel could not be refreshed and the list is the
/// last saved copy. Amber, not red: nothing is broken, the servers still work.
class _StaleNote extends StatelessWidget {
  const _StaleNote();

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.xs, NovaSpace.lg, NovaSpace.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: NovaSpace.md, vertical: NovaSpace.sm),
      decoration: BoxDecoration(
        color: NovaSemantics.amber.withValues(alpha: 0.12),
        borderRadius: NovaRadii.iconChipR,
        border: Border.all(color: NovaSemantics.amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsetsDirectional.only(top: 1),
            child: Icon(Icons.cloud_off_rounded,
                size: 16, color: NovaSemantics.amber),
          ),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Text(
              s.nodeStaleList,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.nova.text),
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
/// The SNI-block bypass switch. Only shown when the list has clean-IP fronted
/// servers, which are the only ones it acts on. Styled as a row of the same
/// list rather than a settings card, because it is a property of this
/// subscription, not of the app.
class _BypassRow extends StatelessWidget {
  const _BypassRow({
    required this.on,
    required this.onChanged,
    required this.onEdit,
    this.note,
  });
  final bool on;
  final ValueChanged<bool> onChanged;

  /// Opens the advanced editor (finalmask / fingerprint / cipher suites).
  final VoidCallback onEdit;

  /// Set when Nova just turned the bypass on by itself, so the row explains.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    final nova = context.nova;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The long description is gone; tapping the title opens the editor, and
        // the switch is the only inline control.
        Row(
          children: <Widget>[
            Expanded(
              child: InkWell(
                onTap: onEdit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NovaSpace.lg, vertical: NovaSpace.md),
                  child: Row(
                    children: <Widget>[
                      NovaIconChip(
                          icon: Icons.shield_moon_rounded,
                          color: nova.warning,
                          size: 36,
                          radius: 10),
                      const SizedBox(width: NovaSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(s.nodeBypassTitle,
                                style: text.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            Text(s.bypassEdit,
                                style: text.labelSmall
                                    ?.copyWith(color: nova.cyan)),
                          ],
                        ),
                      ),
                      Icon(Icons.tune_rounded, size: 18, color: nova.muted),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: NovaSpace.md),
              child: Switch(value: on, onChanged: onChanged),
            ),
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                NovaSpace.lg, 0, NovaSpace.lg, NovaSpace.md),
            child: Text(note!,
                style: text.bodySmall?.copyWith(color: nova.warning)),
          ),
      ],
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
    this.coreDelayMs,
    this.coreTested = false,
    this.active = false,
    this.showDivider = true,
  });

  final ProxyNode node;

  /// Null while the node is still being measured.
  final NodeProbeResult? probe;

  /// Null until the location resolves, and location-free for fronted addresses.
  final _Geo? geo;
  final bool selected;
  final VoidCallback onTap;

  /// The core's live latency for this node through the running tunnel, or null
  /// when disconnected or the core has no figure. Takes precedence over [probe]
  /// because it is measured through the actual path (bypass included).
  final int? coreDelayMs;

  /// True when the core measured this node this round (it may still have failed).
  /// Lets the row say "no response" instead of "not testable" for a dead exit.
  final bool coreTested;

  /// True when the auto-selector is currently routing through this node, so the
  /// row can show which server is really carrying traffic right now.
  final bool active;

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

    // A calm left rail marks the pinned exit (indigo) or, more strongly, the
    // node carrying traffic right now (green). The 3px is always reserved in
    // the border box so a row never shifts sideways when the rail lights up.
    final Color rail = active
        ? NovaSemantics.connectGreen
        : (selected ? nova.indigo : Colors.transparent);

    return Material(
      color: selected ? nova.indigo.withValues(alpha: 0.06) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          selected: selected,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: rail, width: 3),
                bottom: showDivider
                    ? BorderSide(color: nova.border)
                    : BorderSide.none,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(
                NovaSpace.lg - 3, NovaSpace.md, NovaSpace.lg, NovaSpace.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                // A country token: the flag (or a globe for a fronted/unknown
                // address) on its own quiet surface, so the leading column
                // keeps a steady rhythm down the list.
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: nova.surface,
                    borderRadius: NovaRadii.smR,
                    border: Border.all(color: nova.border),
                  ),
                  child: cc.isNotEmpty
                      ? Text(_flagEmoji(cc),
                          style: const TextStyle(fontSize: 20, height: 1))
                      : Icon(Icons.public_rounded, color: nova.muted, size: 20),
                ),
                const SizedBox(width: NovaSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // Primary line: the protocol tag and the node's name. The
                      // name follows the ambient direction, so a Farsi name
                      // reads right-to-left and a Latin one left-to-right, each
                      // ellipsizing on its own trailing edge.
                      Row(
                        children: <Widget>[
                          _ProtoBadge(protocol: node.protocol),
                          const SizedBox(width: NovaSpace.sm),
                          Expanded(
                            child: Text(primary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.15,
                                    letterSpacing: -0.1)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      // Secondary line: the address (always LTR) trailed by the
                      // quiet transport chips. Wraps tidily on a narrow screen
                      // instead of fighting the name for width.
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: NovaSpace.sm,
                        runSpacing: 4,
                        children: <Widget>[
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(addr,
                                style: text.bodySmall?.copyWith(
                                  color: nova.muted,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures()
                                  ],
                                )),
                          ),
                          for (final String t in transport) _MiniTag(text: t),
                        ],
                      ),
                      if (detail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        // Tertiary line: the deep TLS details, kept to one dim
                        // line. Each part truncates on its own so a long SNI
                        // host never grows the row.
                        Row(
                          children: <Widget>[
                            for (int i = 0; i < detail.length; i++) ...<Widget>[
                              if (i > 0) const SizedBox(width: NovaSpace.sm),
                              Flexible(
                                child: Text(detail[i],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelSmall?.copyWith(
                                        color:
                                            nova.muted.withValues(alpha: 0.8),
                                        height: 1.2)),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: NovaSpace.md),
                // The verdict sits in a reserved slot so the latency figures
                // line up as a column the eye can run straight down.
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 54),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _Verdict(
                        probe: probe,
                        coreDelayMs: coreDelayMs,
                        coreTested: coreTested),
                  ),
                ),
                // A fixed trailing zone for the pinned / live marks, so their
                // presence never nudges the verdict column. A green rail
                // already flags the live node, so the check wins the slot when
                // a node is both pinned and carrying traffic.
                SizedBox(
                  width: 24,
                  child: selected
                      ? Icon(Icons.check_circle_rounded,
                          color: nova.indigo, size: 20)
                      : (active
                          ? const Icon(Icons.circle,
                              color: NovaSemantics.connectGreen, size: 9)
                          : null),
                ),
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
        NodeProtocol.mieru => nova.violet,
      };

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final Color c = _color(nova);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        protocol.label.toUpperCase(),
        style: TextStyle(
            color: c,
            fontWeight: FontWeight.w700,
            fontSize: 10,
            height: 1.1,
            letterSpacing: 0.6),
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: nova.surface2,
      ),
      child: Text(text,
          style: TextStyle(
              color: nova.muted,
              fontWeight: FontWeight.w600,
              fontSize: 10,
              height: 1.1,
              letterSpacing: 0.2)),
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
  const _Verdict(
      {required this.probe, this.coreDelayMs, this.coreTested = false});
  final NodeProbeResult? probe;

  /// The running core's live latency for this node, measured through the tunnel
  /// (so with the SNI-block bypass applied). When present it wins over [probe]:
  /// it is the one honest number for a clean-IP node the outside probe had to
  /// call "not testable", and it is fresher than any outside measurement.
  final int? coreDelayMs;

  /// True when the core measured this node this round but it did not answer (no
  /// [coreDelayMs]). That is a real "no response" verdict, not "not testable":
  /// the core tried it through the live tunnel and got nothing back.
  final bool coreTested;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    // A live figure from the running core (measured through the actual tunnel,
    // bypass included) is the truest verdict, so it leads when present. A bolt,
    // not a check: measured live right now is a stronger claim than "reachable".
    final int? live = coreDelayMs;
    if (live != null) {
      return _LatencyBadge(ms: live, icon: Icons.bolt_rounded, filled: true);
    }
    // The core tried this node through the tunnel and got nothing back: an
    // honest "no response", not the misleading "not testable" (it WAS tested).
    if (coreTested) {
      return _VerdictPill(
        label: s.nodeNoResponse,
        color: NovaSemantics.amber,
      );
    }
    final NodeProbeResult? p = probe;
    if (p == null) {
      return const SizedBox(
        width: 15,
        height: 15,
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
        // The quietest verdict of all: a node you cannot judge from outside a
        // tunnel is not a problem, so it whispers in muted text rather than
        // wearing a pill that would read as an alarm.
        return Text(
          s.nodeUntested,
          textAlign: TextAlign.end,
          style: text.labelSmall?.copyWith(
              color: nova.muted, fontWeight: FontWeight.w500, height: 1.1),
        );
      case NodeProbeQuality.proxied:
      case NodeProbeQuality.handshake:
        final int ms = p.latencyMs ?? 0;
        final bool proven = p.quality == NodeProbeQuality.proxied;
        // Proven traffic gets the verified mark on a tinted pill; a
        // handshake-only figure stays plain so it does not overclaim.
        return _LatencyBadge(
          ms: ms,
          icon: proven ? Icons.verified_rounded : null,
          filled: proven,
        );
    }
  }
}

/// A latency reading rendered as a confident, tabular figure: the number leads
/// at full weight, the "ms" unit is demoted to the same hue at lower emphasis,
/// and both take the ping color (green fast, amber middling, red slow). A
/// proven or live reading also earns a tinted pill and a leading mark; a
/// handshake-only number stays plain so it never looks stronger than it is.
class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.ms, this.icon, this.filled = false});

  final int ms;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color c = NovaSemantics.ping(ms);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: filled ? NovaSpace.sm : 0, vertical: 3),
      decoration: filled
          ? BoxDecoration(
              color: c.withValues(alpha: 0.13),
              borderRadius: NovaRadii.iconChipR,
            )
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          // "42 ms" is a Latin run, held LTR so it is never mirrored in Farsi.
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '$ms',
                  style: TextStyle(
                    color: c,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    height: 1,
                    letterSpacing: -0.2,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                  ),
                ),
                TextSpan(
                  text: ' ms',
                  style: TextStyle(
                    color: c.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                    fontSize: 10.5,
                    height: 1,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
            textDirection: TextDirection.ltr,
          ),
        ],
      ),
    );
  }
}

/// A short word verdict on a tint: "blocked" (red) or "no response" (amber).
/// Filled so the word reads as a state, never colour alone; the latency figures
/// use [_LatencyBadge] instead.
class _VerdictPill extends StatelessWidget {
  const _VerdictPill({
    required this.label,
    required this.color,
    this.filled = false,
  });

  final String label;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = Theme.of(context).textTheme.labelMedium!.copyWith(
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
      // A lone Farsi word ("مسدود") is unaffected by the LTR hint, and an
      // English word stays upright too.
      child: Text(label, style: base, textDirection: TextDirection.ltr),
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
