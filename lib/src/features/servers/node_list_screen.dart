import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cleanip/clean_ip_fronting.dart';
import '../../core/cleanip/clean_ip_store.dart';
import '../../core/geo/node_geo_store.dart';
import '../../core/proxy/health_store.dart';
import '../../core/proxy/list_freshness.dart';
import '../../core/proxy/pool_order.dart';
import '../../core/logging/nova_log.dart';
import '../../core/models/proxy_profile.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../core/proxy/singbox/awg_config.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../../core/proxy/singbox/singbox_config.dart';
import '../../core/proxy/subscription.dart';
import '../../l10n/nova_strings.dart';
import 'free_list_search_sheet.dart';
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
  const NodeListScreen({
    super.key,
    required this.profileId,
    this.embedded = false,
  });

  final String profileId;

  /// Rendered inside the dashboard's Configs tab rather than pushed as its own
  /// route: no Scaffold, no app bar, and the rows scroll with the page instead
  /// of in their own viewport. The two actions the app bar carries (refresh and
  /// the lightning test) move into the list's own header.
  final bool embedded;

  @override
  State<NodeListScreen> createState() => _NodeListScreenState();
}

class _NodeListScreenState extends State<NodeListScreen> {
  /// Cap how many servers this screen shows, so a 1000-entry subscription stays
  /// responsive. Deduped by server:port first.
  ///
  /// Matched to the measuring core's own pool cap: anything Nova can put a real
  /// number against should be on screen to receive it. It used to be 80, which
  /// would have quietly truncated a longer list before the lightning test ever
  /// saw it.
  static const int _maxShown = SingboxConfig.kMeasurePoolCap;

  List<ProxyNode> _nodes = <ProxyNode>[];

  /// key -> where the node really is, when that is knowable at all.
  /// Persistent, shared across refreshes and restarts (see NodeGeoStore).
  final NodeGeoStore _geoStore = NodeGeoStore.instance;

  /// host -> resolved geo, so the many nodes sharing one address (a panel hands
  /// out the same clean IP for every protocol) cost one lookup.
  final Map<String, NodeGeo> _geoByHost = <String, NodeGeo>{};

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
    // Flags change when an exit country is learned while connected or a
    // lookup lands; repaint the rows then.
    _geoStore.addListener(_onGeoChanged);
    // Defer to after the first frame: _load() reads NovaScope.of(context),
    // which can't be looked up while initState is still running.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    _loadMeasureHint();
  }

  @override
  void dispose() {
    _geoStore.removeListener(_onGeoChanged);
    _http.close(force: true);
    _search.dispose();
    // Leaving the list stops any sweep it started. The run has no UI anywhere
    // else, so letting it continue spends the user's battery and holds a
    // measuring core open for a screen they have walked away from, and until it
    // finished they could not connect (a measuring core needs the tunnel down).
    unawaited(_proxyForDispose?.cancelMeasure());
    super.dispose();
  }

  /// Captured while the tree is still mounted: dispose() cannot reach an
  /// InheritedWidget through the context any more.
  ProxyController? _proxyForDispose;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _proxyForDispose = NovaScope.of(context).proxy;
  }

  void _onGeoChanged() {
    if (mounted) setState(() {});
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
      _geoStore[_key(n)]?.place ?? '',
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

  /// The one-time "what the bolt does" note. Persisted, so it appears the first
  /// time a subscription is opened and never again once it is dismissed.
  static const String _kMeasureHintSeen = 'nova.node.measureHintSeen';
  bool _measureHintSeen = true;

  Future<void> _loadMeasureHint() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _measureHintSeen = prefs.getBool(_kMeasureHintSeen) ?? false);
  }

  Future<void> _dismissMeasureHint() async {
    setState(() => _measureHintSeen = true);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMeasureHintSeen, true);
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
    // Put the last sweep's numbers back before anything else runs. A full sweep
    // costs a minute or two, and it used to be lost to anything that tore the
    // app down (on Android, the back button was enough), so the next open
    // started from nothing and re-tested.
    if (!mounted) return;
    final ProxyController proxy = NovaScope.of(context).proxy;
    if (proxy.coreHealth.value.isEmpty) {
      final CoreNodeHealth? saved = await HealthStore.load(profile.id);
      if (saved != null && mounted) {
        proxy.coreHealth.value = saved;
        // The count follows the restored list too, so reopening the app shows
        // the number the user was left with rather than the pool size again.
        _syncShownCount(saved);
      }
    }
    // Only go to the network when the saved list is actually old. Re-fetching
    // and re-sweeping on every visit made a tab switch cost a few hundred
    // dials, and threw away readings the user had just watched appear. The
    // refresh button ignores this and always fetches.
    // The three cases that justify going to the network, and nothing else: a
    // list with no servers yet, a list past its window, and the refresh button
    // (which never reaches here). Switching server, connecting and coming back
    // to the tab are not among them.
    if (!mounted) return;
    final bool autoOn = NovaScope.of(context).settings.autoRefreshLists;
    if (cached.isNotEmpty && (!autoOn || !ListFreshness.isStale(profile.id))) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _refresh(profile, hadCache: cached.isNotEmpty);
    await ListFreshness.markSynced(profile.id);
  }

  /// Fetches the subscription live and updates the list, keeping whatever is on
  /// screen if the fetch fails. Shared by the initial load and the manual
  /// refresh button. [hadCache] means the list is already populated, so a
  /// failure is a soft "stale" note rather than a fatal error.
  Future<void> _refresh(ProxyProfile profile,
      {required bool hadCache}) async {
    if (mounted) setState(() => _refreshing = true);
    try {
      final List<ProxyNode> all = await resolveProfileNodes(profile);
      if (!mounted) return;
      _applyNodes(all, profile, stale: lastResolveWasStale);
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
  /// entries and the real count.
  ///
  /// It does not test anything. Nova used to probe a list the moment it was
  /// opened or refreshed; that probe hung, could not judge most protocols, and
  /// fought the lightning test for the same sockets. Testing is now something
  /// the user asks for, and only ever through the core.
  void _applyNodes(List<ProxyNode> all, ProxyProfile profile,
      {required bool stale}) {
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
    // Nova's own list gets this install's order, before the cap below, so the
    // servers a device sweeps and keeps are not the same ones every other
    // device keeps. See PoolOrder. A subscription the user added keeps the
    // order their provider sent, which is theirs to decide.
    final List<ProxyNode> ordered =
        profile.isBuiltIn ? PoolOrder.shuffled(all) : all;
    final Set<String> seen = <String>{};
    final List<ProxyNode> deduped = <ProxyNode>[];
    for (final ProxyNode n in ordered) {
      if (seen.add(_key(n))) deduped.add(n);
      if (deduped.length >= _maxShown) break;
    }
    // The count on the card is what the user can actually choose between: the
    // deduped list, not the raw number of lines in the subscription. Nova's own
    // free list carries the same server three times over, so the raw count
    // promised eighteen servers where there were twelve.
    profiles.update(profile.copyWith(nodeCount: deduped.length));
    setState(() {
      _nodes = deduped;
      _loading = false;
      _refreshing = false;
    });
  }

  /// The refresh button: re-fetch the subscription now and put the fresh list
  /// up, with every ping cleared and none taken.
  ///
  /// On a subscription the user added, that is the whole job: their provider's
  /// servers are theirs, and testing them is the lightning button's business.
  ///
  /// On Nova's own free list it is not. That pool is a few hundred other
  /// people's servers, most of which are gone at any moment, so a bare list of
  /// two hundred untested rows is not something anyone can pick from. Refresh
  /// there searches, behind the screen that shows the count and can be stopped,
  /// and hands back a list that works. This is the user asking, so it is not
  /// the automatic testing that was removed: nothing starts until this button.
  ///
  /// If this profile is the live tunnel it reconnects, so the freshest list's
  /// best node is the one carrying traffic.
  Future<void> _manualRefresh() async {
    final ProxyProfile? profile = _profile;
    if (profile == null || _refreshing) return;
    clearSubscriptionCache();
    // A provider can move a server off Cloudflare between updates, so the
    // is-this-fronted answers are re-asked with the fresh list.
    CleanIpFronting.forgetLookups();
    // Refresh means the readings on screen are gone: every row goes back to
    // "not tested" and the saved ones are dropped, here and on disk, so nothing
    // survives that describes servers this list may no longer even carry.
    final profiles = NovaScope.of(context).profiles;
    NovaScope.of(context).proxy.coreHealth.value = CoreNodeHealth.empty;
    // The seed order was built from those readings, so it goes too rather than
    // pointing the next connect at servers this list may no longer carry.
    profiles.update(
        profile.copyWith(lastLatencyMs: null, fastNodes: const <String>[]));
    await ListFreshness.invalidate(profile.id);
    await HealthStore.clear(profile.id);
    await _refresh(profile, hadCache: _nodes.isNotEmpty);
    if (!mounted) return;
    if (profile.isBuiltIn) {
      await _boostFreeListAddresses();
      if (!mounted) return;
      await _searchFreeList(profile);
    }
    if (!mounted) return;
    final scope = NovaScope.of(context);
    if (scope.proxy.state.isActive &&
        scope.proxy.activeProfile?.id == profile.id) {
      NovaLog.instance.write('Manual refresh: reconnecting to the best server');
      await scope.proxy.reconnect();
    }
  }

  /// Re-addresses the fresh free list through the best addresses Radar found,
  /// when the user has asked for that.
  ///
  /// The free list's servers are handed out by domain, and in Iran those domains
  /// are filtered within days while the Cloudflare addresses behind them keep
  /// working. A scan already finds addresses that are fast from THIS network, so
  /// this puts them to use: each server gets one of the best few at random, the
  /// domain moves to the TLS name so the server still sees what it expects, and
  /// the search below then measures the list as re-addressed rather than as it
  /// arrived.
  ///
  /// Off unless the user turned it on in Radar, and a no-op when no scan has run
  /// or its addresses have aged out.
  Future<void> _boostFreeListAddresses() async {
    final CleanIpStore store = CleanIpStore.instance;
    if (!store.boostFreeList) return;
    final List<CleanIp> pool = store.freshPool;
    if (pool.isEmpty || _nodes.isEmpty) return;
    final List<ProxyNode> rewritten =
        await CleanIpFronting.applySpread(_nodes, pool);
    if (!mounted) return;
    setState(() => _nodes = rewritten);
  }

  /// Searches the freshly fetched free list behind a blocking screen, until it
  /// has a list worth handing over.
  ///
  /// "Worth handing over" is [kFreeListTarget] servers that answered, of which
  /// at least [kFreeListFastMin] are under [kFreeListFastMs]. Thirty servers
  /// that all answer in two seconds is a list nobody wants, so when the fast
  /// ones are not among the first thirty the search keeps going into the rest of
  /// the pool instead of stopping on a technicality. If the pool runs out first,
  /// whatever was found stands.
  Future<void> _searchFreeList(ProxyProfile profile) async {
    if (_nodes.isEmpty) return;
    final ProxyController proxy = NovaScope.of(context).proxy;
    if (!proxy.canMeasureNodes || proxy.measuring.value) return;
    if (proxy.state != ProxyConnectionState.disconnected) return;

    final int total = _nodes.length;
    bool closed = false;
    void close() {
      if (closed || !mounted) return;
      closed = true;
      Navigator.of(context, rootNavigator: true).pop();
    }

    // Locking the screen used to crash Nova on iOS mid-search, and it is easy to
    // see why the window existed: the sweep kept dialling dozens of servers
    // while the system was tearing the app's networking down around it. Nothing
    // good comes of measuring servers with the screen off in any case, so the
    // search stops when the app leaves the foreground rather than racing the
    // system. The partial results already measured are kept.
    AppLifecycleListener? life;
    void stopForBackground() {
      unawaited(proxy.cancelMeasure());
      close();
    }

    life = AppLifecycleListener(
      onPause: stopForBackground,
      onDetach: stopForBackground,
    );

    unawaited(showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '',
      // Opaque and over everything, including the bottom navigation: while this
      // is up the rest of the app cannot be used, which is the point. A
      // half-searched list is not something to let anyone pick from.
      barrierColor: Theme.of(context).colorScheme.surface,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (BuildContext ctx, _, __) => FreeListSearchSheet(
        proxy: proxy,
        total: total,
        onStop: () {
          unawaited(proxy.cancelMeasure());
          close();
        },
      ),
    ));

    try {
      await _measureAll(quiet: true, stopWhen: _freeListSearchDone);
    } finally {
      life.dispose();
      await ListFreshness.markSynced(profile.id);
      close();
    }
  }

  /// Enough servers, and enough of them fast. See [_searchFreeList].
  static bool _freeListSearchDone(Map<String, int> delays) {
    if (delays.length < kFreeListTarget) return false;
    int fast = 0;
    for (final int ms in delays.values) {
      if (ms < kFreeListFastMs) fast++;
    }
    return fast >= kFreeListFastMin;
  }

  /// The lightning button: measure every listed server through a measuring
  /// core (see ProxyController.measureNodes). Results land on coreHealth, which
  /// the rows already render as the live bolt badge / "no response".
  Future<void> _measureAll({
    bool quiet = false,
    int? stopAfter,
    bool Function(Map<String, int> delays)? stopWhen,
  }) async {
    if (_nodes.isEmpty) return;
    final scope = NovaScope.of(context);
    final NovaStrings s = NovaStrings.of(context);
    // Re-testing the free list means the servers on screen, not the pool they
    // were found in. Pulling all two hundred back in turned a ten-second check
    // of a working list into the whole search again, which is what refresh is
    // for.
    final CoreNodeHealth health = scope.proxy.coreHealth.value;
    final bool bounded = stopAfter != null || stopWhen != null;
    final List<ProxyNode> subject = (!bounded && !health.isEmpty)
        ? _hideDead(_nodes, health)
        : _nodes;
    final String? problem = await scope.proxy.measureNodes(
        List<ProxyNode>.of(subject),
        merge: subject.length != _nodes.length,
        stopAfterWorking: stopAfter,
        stopWhen: stopWhen);
    await _persistHealth(scope.proxy.coreHealth.value);
    if (!mounted) return;
    // Stopping early is a normal ending, so the count has to follow the list
    // whether the sweep finished or the user ended it.
    _syncShownCount(scope.proxy.coreHealth.value);
    if (quiet) return;
    final String msg = problem ??
        s.nodeMeasureDone.replaceFirst('{n}', '${_nodes.length}');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Keeps a lightning test's numbers: on disk against this profile, and as the
  /// profile's own seed order for the next connect.
  ///
  /// The lightning test is now the only thing in Nova that measures a server, so
  /// it is also the only thing that can say which exits Auto should reach for
  /// first. That used to come from the outside probe, which is gone; without
  /// this the seed order would simply have gone empty.
  Future<void> _persistHealth(CoreNodeHealth health) async {
    final ProxyProfile? profile = _profile;
    if (profile == null) return;
    await HealthStore.save(profile.id, health);
    if (!mounted) return;
    final List<MapEntry<String, int>> ranked = health.delayMsByKey.entries
        .toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          a.value.compareTo(b.value));
    if (ranked.isEmpty) return;
    NovaScope.of(context).profiles.update(profile.copyWith(
          lastLatencyMs: ranked.first.value,
          fastNodes: ranked
              .take(24)
              .map((MapEntry<String, int> e) => e.key)
              .toList(),
        ));
  }

  /// The number the card should show: what the user can actually choose
  /// between, after the free list's own filtering.
  ///
  /// The card used to show the size of the pool. On the free list that is a few
  /// hundred candidates that exist to be searched, not read, so someone who
  /// stopped the search at ten working servers was told they had 144. The
  /// number has to describe the list in front of them or it means nothing.
  int _shownCount(CoreNodeHealth health) => _hideDead(_nodes, health).length;

  /// Publishes that number, when it has changed.
  void _syncShownCount(CoreNodeHealth health) {
    final ProxyProfile? profile = _profile;
    if (profile == null) return;
    final int n = _shownCount(health);
    if (n == 0 || n == profile.nodeCount) return;
    NovaScope.of(context).profiles.update(profile.copyWith(nodeCount: n));
  }

  /// Hides the servers the last sweep proved dead, on Nova's own free list.
  ///
  /// A view decision, taken from the CURRENT measurement and nothing else. The
  /// list itself always holds every server the subscription carries, so the next
  /// sweep re-tests all of them and anything that comes back is simply visible
  /// again. Persisting a blacklist instead looked equivalent and was not: each
  /// sweep then only saw the survivors, so an unlucky run shrank the list, the
  /// next run shrank what was left, and nothing short of a manual refresh ever
  /// undid it. Measured against a deliberately blocked pair it went 18 to 7 to
  /// 3 in two visits.
  ///
  /// Never applied to a subscription the user added: their provider's list is
  /// theirs, and a server that is down today is one they may want to see.
  ///
  /// If every server failed it hides nothing. That is this connection, not
  /// those servers, and an empty list is a worse answer than a stale one.
  List<ProxyNode> _hideDead(List<ProxyNode> nodes, CoreNodeHealth health) {
    final ProxyProfile? profile = _profile;
    if (profile == null || !profile.isBuiltIn) return nodes;
    // On Nova's own list, show the servers that answered and nothing else.
    //
    // The pool behind this is a few hundred entries that exist to be searched,
    // not read. Once the sweep has what it needs it stops, which used to leave
    // the rest of the list spinning for ever with no way to settle them, and a
    // list where half the rows are a question mark is not a list anyone can
    // pick from. Showing only the servers with a number means every row on
    // screen is one the user can actually use.
    final List<ProxyNode> working =
        nodes.where((ProxyNode n) => health.delayFor(n) != null).toList();
    if (working.isNotEmpty) {
      return working.length <= kFreeListTarget
          ? working
          : working.sublist(0, kFreeListTarget);
    }
    // Nothing has been measured yet (a fresh install, or a sweep that has not
    // started): show the pool rather than an empty screen.
    return nodes;
  }

  /// Tapping one row's verdict: re-test just that server, keeping every other
  /// row's reading. Same measuring core as the lightning button, a pool of one.
  Future<void> _measureOne(ProxyNode node) async {
    final scope = NovaScope.of(context);
    if (scope.proxy.measuring.value) return;
    final String? problem =
        await scope.proxy.measureNodes(<ProxyNode>[node], merge: true);
    await _persistHealth(scope.proxy.coreHealth.value);
    if (!mounted) return;
    _syncShownCount(scope.proxy.coreHealth.value);
    if (problem == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(problem)));
  }

  /// Turn the bypass on or off by hand. Reconnects if this profile is the live
  /// tunnel, so the change takes effect without a second tap.
  Future<void> _setBypass(bool on) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null || profile.hardenTls == on) return;
    NovaLog.instance.write(
        'You turned the SNI-block bypass ${on ? 'on' : 'off'} for "${profile.name}"');
    // Mark it decided: a subscription can ask for this on by default, and once
    // the user has chosen, a refresh must not quietly change it back.
    final updated = profile.copyWith(hardenTls: on, hardenTlsUserSet: true);
    scope.profiles.update(updated);
    _bypassSuggested = false;
    if (mounted) setState(() {});
    if (scope.proxy.activeProfile?.id == profile.id) {
      scope.proxy.selectProfile(updated);
      if (scope.proxy.state.isActive) await scope.proxy.reconnect();
    }
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
    final String key = _key(n);
    // Already known (from a previous session, or the real exit observed while
    // connected): keep it. The flag must not be re-guessed or lost on every
    // refresh, and an observed exit beats any lookup.
    final NodeGeo? known = _geoStore[key];
    if (known != null) return;
    final NodeGeo? cached = _geoByHost[host];
    if (cached != null) {
      _geoStore.setGuess(key, cached);
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
      final NodeGeo g;
      if (front != null) {
        g = NodeGeo(frontedBy: front);
      } else {
        final cc = (j['country_code'] as String?)?.toUpperCase() ?? '';
        final country = (j['country'] as String?) ?? '';
        final city = (j['city'] as String?) ?? '';
        // Lead with the city (the distinguishing part; the flag already shows
        // the country), kept short with the country code. Fall back to country.
        final String place =
            city.isNotEmpty ? (cc.isNotEmpty ? '$city, $cc' : city) : country;
        g = NodeGeo(countryCode: cc, place: place);
      }
      _geoByHost[host] = g;
      _geoStore.setGuess(key, g);
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
    final Widget body = _loading
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()))
        : _error != null
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text(_error!)))
            // The core's live per-node latency lands while the tunnel is up;
            // rebuild the rows when it changes so the SNI-blocked servers can
            // show a real ping (and which one is carrying traffic) at last.
            : ValueListenableBuilder<CoreNodeHealth>(
                valueListenable: NovaScope.of(context).proxy.coreHealth,
                builder: (BuildContext context, CoreNodeHealth health, _) =>
                    _list(s, visible, pinned, health),
              );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.name ?? 'Nodes'),
        actions: <Widget>[
          if (!_loading) ..._actions(s),
        ],
      ),
      body: body,
    );
  }

  /// Refresh and the lightning test. In the app bar when this is its own
  /// screen, in the list's header when it is embedded in the dashboard.
  List<Widget> _actions(NovaStrings s) => <Widget>[
        // "Test all through the core": a second, tunnel-less core dials every
        // server exactly as a tunnel would and reports the round-trip, so the
        // nodes the outside probe can only call "not testable" (Reality,
        // obfuscated Hysteria2, SS2022, clean-IP VLESS behind an SNI block) get
        // a real number. Only where the host can run one.
        if (NovaScope.of(context).proxy.canMeasureNodes)
          ValueListenableBuilder<bool>(
            valueListenable: NovaScope.of(context).proxy.measuring,
            // While a run is in flight the button stops it instead of going
            // dead. A sweep over a few hundred servers on a bad connection can
            // take minutes, because every server waits out its own timeout, and
            // a disabled button in the middle of that reads as a frozen app
            // with no way out.
            builder: (BuildContext context, bool busy, _) => IconButton(
              tooltip: busy ? s.nodeMeasureStop : s.nodeMeasureAll,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          CircularProgressIndicator(strokeWidth: 2),
                          Icon(Icons.stop_rounded, size: 11),
                        ],
                      ),
                    )
                  : const Icon(Icons.bolt_rounded),
              onPressed: busy
                  ? () => NovaScope.of(context).proxy.cancelMeasure()
                  : _measureAll,
            ),
          ),
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
      ];

  /// The header blocks are a handful of cheap widgets; the node rows are built
  /// on demand so an 80-node subscription only lays out what is on screen.
  Widget _list(NovaStrings s, List<ProxyNode> visibleUnsorted, String? pinned,
      CoreNodeHealth health) {
    final ProxyController proxy = NovaScope.of(context).proxy;
    final bool canMeasure = proxy.canMeasureNodes;
    final bool measuring = proxy.measuring.value;
    // Ranking, best first. When connected, the core's live pings win: a node the
    // core actually measured through the tunnel leads (lowest ping first), so the
    // working servers surface at the top. With nothing measured yet every row
    // ranks the same and the list keeps the order it arrived in. A node still
    // being measured keeps its place until its verdict lands, so rows don't jump
    // while the list fills.
    int rank(ProxyNode n) {
      final int? live = health.delayFor(n);
      if (live != null) return live; // 0..~, measured nodes first by ping
      if (health.wasTested(n)) return 1000000; // tested but no response
      return 2000000; // not tested
    }

    final List<ProxyNode> visible = <ProxyNode>[
      ..._hideDead(visibleUnsorted, health)
    ]..sort((ProxyNode a, ProxyNode b) => rank(a).compareTo(rank(b)));
    final List<Widget> header = <Widget>[
      if (widget.embedded && !_loading)
        Padding(
          padding: const EdgeInsets.only(right: NovaSpace.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: _actions(s),
          ),
        ),
      if (!_measureHintSeen && canMeasure && visibleUnsorted.isNotEmpty)
        _MeasureHint(onDismiss: _dismissMeasureHint),
      if (_stale) const _StaleNote(),
      if (!_skipped.isEmpty) _SkippedNote(skipped: _skipped),
      // Nova's own channels belong on Nova's own list. Someone looking at the
      // subscription they bought from their own provider did not come here for
      // our Telegram, and putting it on their servers reads as advertising in
      // a place that is not ours.
      if (_profile?.isBuiltIn ?? false) ...<Widget>[
        const _SocialRow(),
        const Divider(height: 1),
      ],
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
      // Embedded, the page around it owns the scrolling; on its own screen this
      // list is the scroll view.
      shrinkWrap: widget.embedded,
      physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.only(
          bottom: widget.embedded
              ? 0
              : NovaSpace.xl + MediaQuery.viewPaddingOf(context).bottom),
      itemCount: header.length + visible.length,
      itemBuilder: (BuildContext context, int i) {
        if (i < header.length) return header[i];
        final int r = i - header.length;
        final ProxyNode n = visible[r];
        // The flag is worked out for rows that actually get built, so a
        // two-hundred-server list does not fire two hundred lookups the moment
        // it opens. Cheap, cached by host, and nothing to do with testing.
        unawaited(_geoOne(n));
        return _NodeRow(
          node: n,
          geo: _geoStore[_key(n)],
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
          onRetest: canMeasure && !measuring ? () => _measureOne(n) : null,
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
    (Icons.send_rounded, 'Telegram', 'https://t.me/irnova'),
    (Icons.camera_alt_rounded, 'Instagram', 'https://instagram.com/irnova_team'),
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

/// The one-time note introducing the lightning test, shown the first time a
/// subscription's server list is opened. It points at the control it describes
/// and carries its own dismiss, so nothing about it is a mystery and nothing
/// about it is permanent.
class _MeasureHint extends StatelessWidget {
  const _MeasureHint({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final NovaStrings s = NovaStrings.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.xs),
      padding: const EdgeInsets.all(NovaSpace.md),
      decoration: BoxDecoration(
        color: nova.indigo.withValues(alpha: 0.08),
        borderRadius: NovaRadii.cardR,
        border: Border.all(color: nova.indigo.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.bolt_rounded, size: 20, color: nova.indigo),
          const SizedBox(width: NovaSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.nodeMeasureHint,
                    style: text.bodySmall?.copyWith(height: 1.35)),
                const SizedBox(height: NovaSpace.xs),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: onDismiss,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: NovaSpace.md),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text(s.nodeMeasureHintGot),
                  ),
                ),
              ],
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
    // The SNI only earns a line when it differs from the host already shown in
    // the address; repeating the same workers.dev name is pure noise.
    if ((n.sni ?? '').isNotEmpty && n.sni!.toLowerCase() != n.server.toLowerCase())
      'SNI ${n.sni}',
  ];
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.geo,
    required this.selected,
    required this.onTap,
    this.onRetest,
    this.coreDelayMs,
    this.coreTested = false,
    this.active = false,
    this.showDivider = true,
  });

  final ProxyNode node;

  /// Tapping the verdict re-tests just this server through the measuring core,
  /// leaving every other row's reading alone. Null while a run is in flight.
  final VoidCallback? onRetest;

  /// Null until the location resolves, and location-free for fronted addresses.
  final NodeGeo? geo;
  final bool selected;
  final VoidCallback onTap;

  /// The core's live latency for this node, measured through the core. Null
  /// until a lightning test (or a single-row test) has produced one.
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
    // The name is the server's own, always. Where the node is only drives the
    // flag (and a small detail below); the owner's labels are what users
    // recognise, and a guessed city used to replace them.
    final String location = geo?.place ?? '';
    final String primary = clean.isNotEmpty ? clean : addr;
    final List<String> transport = <String>[
      ..._transportTags(node),
      if (geo?.frontedBy != null) geo!.frontedBy!,
    ];
    final List<String> detail = <String>[
      ..._nodeDetail(node),
      if (location.isNotEmpty) location,
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
                      // Primary: the node's name, alone on its line so it is the
                      // one thing the eye lands on. It follows the ambient
                      // direction, so a Farsi name reads right-to-left and a
                      // Latin one left-to-right, each ellipsizing on its own
                      // trailing edge.
                      Text(primary,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                              letterSpacing: -0.1)),
                      const SizedBox(height: NovaSpace.xs),
                      // Secondary: what this server is. The protocol tag anchors
                      // the line in colour, then the address (always LTR) fills
                      // the rest on a single tidy line, middle-truncated so a
                      // long workers.dev host keeps its port in view instead of
                      // wrapping to two lines.
                      Row(
                        children: <Widget>[
                          _ProtoBadge(
                            protocol: node.protocol,
                            awgVersion: awgVersionLabel(node.awgConf),
                          ),
                          const SizedBox(width: NovaSpace.sm),
                          Expanded(
                            child: Directionality(
                              textDirection: TextDirection.ltr,
                              child: _MiddleEllipsis(
                                text: addr,
                                style: text.bodySmall?.copyWith(
                                  color: nova.muted,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (transport.isNotEmpty || detail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 3),
                        // Tertiary: one quiet metadata cluster. The transport
                        // tags read as a low-key group, then the deep TLS
                        // details trail as dim text on the same line and
                        // truncate together, so the handshake internals never
                        // add a whole extra line of noise.
                        Row(
                          children: <Widget>[
                            for (int i = 0; i < transport.length; i++) ...<Widget>[
                              if (i > 0) const SizedBox(width: NovaSpace.xs),
                              _MiniTag(text: transport[i]),
                            ],
                            if (transport.isNotEmpty && detail.isNotEmpty)
                              const SizedBox(width: NovaSpace.sm),
                            if (detail.isNotEmpty)
                              Flexible(
                                child: Text(detail.join('   '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelSmall?.copyWith(
                                        color: nova.muted
                                            .withValues(alpha: 0.75),
                                        height: 1.2)),
                              ),
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
                    // Tapping the number re-tests this one server. The hit area
                    // is padded out to a comfortable target without moving the
                    // column the figures line up in.
                    child: Semantics(
                      button: onRetest != null,
                      label: NovaStrings.of(context).nodeRetestOne,
                      child: InkWell(
                        onTap: onRetest,
                        borderRadius: BorderRadius.circular(NovaRadii.sm),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: NovaSpace.xs, vertical: NovaSpace.xs),
                          child: _Verdict(
                              coreDelayMs: coreDelayMs,
                              coreTested: coreTested),
                        ),
                      ),
                    ),
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
  const _ProtoBadge({required this.protocol, this.awgVersion});
  final NodeProtocol protocol;

  /// For AmneziaWG, which generation the server is offering ("3", "2"), so the
  /// badge reads AMNEZIAWG VER 3. Null when the config says nothing about it,
  /// and the badge stays as it was rather than claiming a version.
  final String? awgVersion;

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
        awgVersion == null
            ? protocol.label.toUpperCase()
            : '${protocol.label.toUpperCase()} VER $awgVersion',
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
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: nova.surface2,
      ),
      child: Text(text,
          style: TextStyle(
              color: nova.muted,
              fontWeight: FontWeight.w600,
              fontSize: 9.5,
              height: 1.1,
              letterSpacing: 0.2)),
    );
  }
}

/// Renders text on a single line, dropping characters from the MIDDLE when it
/// will not fit, so a long host keeps both its readable start and its trailing
/// port ("lively-heron-...workers.dev:443") instead of losing the tail to a
/// plain end-ellipsis or wrapping onto a second line. Measured against the real
/// available width, so it stays honest at any screen size.
class _MiddleEllipsis extends StatelessWidget {
  const _MiddleEllipsis({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxWidth = constraints.maxWidth;

        double widthOf(String s) {
          final TextPainter tp = TextPainter(
            text: TextSpan(text: s, style: style),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout();
          return tp.width;
        }

        Widget oneLine(String s) => Text(
              s,
              style: style,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              textDirection: TextDirection.ltr,
            );

        if (text.length <= 8 || widthOf(text) <= maxWidth) {
          return oneLine(text);
        }

        const String ellipsis = '…';
        String best = text;
        for (int keep = text.length - 1; keep >= 8; keep--) {
          final int head = (keep + 1) ~/ 2;
          final int tail = keep - head;
          final String candidate = text.substring(0, head) +
              ellipsis +
              text.substring(text.length - tail);
          best = candidate;
          if (widthOf(candidate) <= maxWidth) break;
        }
        return oneLine(best);
      },
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
  const _Verdict({this.coreDelayMs, this.coreTested = false});

  /// The core's latency for this node. Nova measures one way only: through the
  /// core, when the user asks for it. The outside TCP/TLS probe that used to
  /// fill this column ran on its own, could not judge Reality, Hysteria2, SS2022
  /// or mieru at all, and competed with the lightning test for sockets.
  final int? coreDelayMs;

  /// True when the core tried this node and got nothing back. That is a real
  /// "no response", as opposed to a node nobody has tested yet.
  final bool coreTested;

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;
    final int? live = coreDelayMs;
    if (live != null) {
      return _LatencyBadge(ms: live, icon: Icons.bolt_rounded);
    }
    if (coreTested) {
      return _VerdictPill(
        label: s.nodeNoResponse,
        color: NovaSemantics.amber,
      );
    }
    // Nobody has tested this server. Said quietly, in muted text: it is not a
    // problem, it is just a row waiting for the lightning button.
    return Text(
      s.nodeNotTested,
      textAlign: TextAlign.end,
      style: text.labelSmall?.copyWith(
          color: nova.muted, fontWeight: FontWeight.w500, height: 1.1),
    );
  }
}

/// A latency reading rendered as a calm, confident metric rather than a sticker:
/// no pill, no border. The number leads at full weight, the "ms" unit is demoted
/// to the same hue at lower emphasis, and both take the ping color (green fast,
/// amber middling, red slow). A live core reading gets a small leading bolt and
/// a proven reading a quiet leading dot; a handshake-only number stays plain so
/// it never looks stronger than it is.
class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.ms, this.icon});

  final int ms;

  /// A small leading glyph for a live core reading (a bolt). Null otherwise.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final Color c = NovaSemantics.ping(ms);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 3),
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
      );
  }
}

/// A short word verdict on a tint: "no response" (amber). Filled so the word
/// reads as a state, never colour alone; the latency figures use
/// [_LatencyBadge] instead.
class _VerdictPill extends StatelessWidget {
  const _VerdictPill({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;
  static const bool filled = true;

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
