// Subscription support: fetch a Nova Proxy `/sub` link, expand it into nodes,
// and derive the "core config" (the template + worker host) the rest of the app
// reads from.
//
// This is the missing piece behind the feedback that the client must read from
// the core: a Nova subscription is a base64 (or plaintext) list of `vless://`
// links that all share one template (uuid/host/sni/fp/path); only the address
// and name differ. We parse them, keep one as the template, and let the Radar
// stamp clean IPs into it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/proxy_profile.dart';
import 'fragment_proxy.dart';
import 'singbox/awg_config.dart';
import 'singbox/proxy_node.dart';
import 'singbox/singbox_outbound_import.dart';
import 'singbox/share_link.dart';

/// Fetches the raw body of a subscription URL. Injectable so tests don't hit
/// the network.
typedef SubscriptionFetcher = Future<String> Function(Uri url);

/// Plan usage/expiry parsed from a subscription's `subscription-userinfo`
/// response header (the de-facto standard: `upload=..; download=..; total=..;
/// expire=..`, bytes and a unix-seconds expiry). Powers the dashboard EXPIRY
/// field and the Stats usage readout.
class SubInfo {
  const SubInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire,
  });

  final int upload;
  final int download;
  final int total; // 0 = unlimited
  final DateTime? expire;

  int get used => upload + download;
  int get remaining => total > 0 ? (total - used).clamp(0, total) : 0;

  static SubInfo? parse(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final Map<String, String> kv = <String, String>{};
    for (final String part in header.split(';')) {
      final int eq = part.indexOf('=');
      if (eq > 0) {
        kv[part.substring(0, eq).trim().toLowerCase()] =
            part.substring(eq + 1).trim();
      }
    }
    if (kv.isEmpty) return null;
    int n(String k) => int.tryParse(kv[k] ?? '') ?? 0;
    final int exp = n('expire');
    return SubInfo(
      upload: n('upload'),
      download: n('download'),
      total: n('total'),
      expire: exp > 0 ? DateTime.fromMillisecondsSinceEpoch(exp * 1000) : null,
    );
  }
}

/// Session cache of the last parsed [SubInfo] per subscription URL.
final Map<String, SubInfo> _subInfoCache = <String, SubInfo>{};

/// Where the plan figures are kept between runs. Set once at startup.
///
/// Without this the used/remaining line on a subscription row was blank until
/// something happened to re-fetch that subscription in this session, which on a
/// cached list could be never. The figures are the provider's own numbers and
/// change slowly, so the last ones seen are the right thing to show while a
/// fresher set is on its way.
SubInfoStore? subInfoStore;

/// Persists the last [SubInfo] seen for a subscription URL.
abstract class SubInfoStore {
  Map<String, SubInfo> loadAll();
  Future<void> save(String url, SubInfo info);
}

/// Seeds the session cache from [subInfoStore]. Called once at startup, before
/// the first frame that could read a plan figure.
void hydrateSubInfo() {
  final SubInfoStore? store = subInfoStore;
  if (store == null) return;
  _subInfoCache.addAll(store.loadAll());
}

/// The most recently seen plan usage/expiry for [subscriptionUrl], if any.
SubInfo? subInfoFor(String? subscriptionUrl) =>
    subscriptionUrl == null ? null : _subInfoCache[subscriptionUrl];

/// The core configuration derived from a subscription: every node plus the
/// template used to stamp Radar-found clean IPs into real, connectable nodes.
class NovaCoreConfig {
  NovaCoreConfig({required this.template, required this.nodes});

  /// A representative node carrying the shared auth/TLS/transport fields.
  final ProxyNode template;

  /// All nodes the subscription returned (banner node included).
  final List<ProxyNode> nodes;

  /// The Cloudflare Worker host clients must present as SNI / WS host. Falls
  /// back through the template fields so it is always non-empty for a TLS node.
  String get workerHost =>
      (template.wsHost?.isNotEmpty ?? false)
          ? template.wsHost!
          : (template.sni?.isNotEmpty ?? false)
              ? template.sni!
              : template.server;

  /// The SNI to present on the TLS handshake (the worker host).
  String? get sni => template.sni ?? template.wsHost;

  /// Builds a config from already-parsed nodes, or `null` if there are none.
  /// Prefers a real Nova node (one carrying a uuid) as the template over the
  /// free-notice banner, though both share the same template fields.
  static NovaCoreConfig? fromNodes(List<ProxyNode> nodes) {
    if (nodes.isEmpty) return null;
    final ProxyNode template = nodes.firstWhere(
      (n) => (n.uuid ?? '').isNotEmpty,
      orElse: () => nodes.first,
    );
    return NovaCoreConfig(template: template, nodes: nodes);
  }
}

/// What a subscription contained that Nova could not turn into a node.
///
/// A dropped line used to vanish without a word, which is how an operator who
/// created a NaiveProxy or mieru inbound found it "appeared in no client at
/// all": the app knew it had skipped something and said nothing. Counting the
/// schemes lets the UI name them.
class SkippedLinks {
  SkippedLinks(this.byScheme);

  /// Lowercased scheme (`mieru`, `naive+quic`, …) to how many lines used it.
  /// `?` collects lines with no scheme Nova could read at all.
  final Map<String, int> byScheme;

  int get total => byScheme.values.fold(0, (int a, int b) => a + b);
  bool get isEmpty => byScheme.isEmpty;

  /// The schemes, most common first, for a short human list.
  List<String> get schemes {
    final List<MapEntry<String, int>> e = byScheme.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    return e.map((MapEntry<String, int> x) => x.key).toList();
  }
}

/// The schemes skipped by the most recent [parseSubscriptionBody] call.
///
/// Deliberately a side channel rather than a changed return type: every caller
/// wants the nodes, and only the node list wants to explain the gaps.
SkippedLinks lastSkippedLinks = SkippedLinks(<String, int>{});

/// Parses a subscription body (base64 or plaintext newline-separated links)
/// into nodes, skipping anything that doesn't parse.
List<ProxyNode> parseSubscriptionBody(String body) {
  final String text = _maybeBase64Decode(body.trim());
  // The panel's own `target=nova` returns a sing-box config document, not a
  // list of share links; the line parser below finds nothing in it, which is
  // how a Nova-target subscription imported with zero servers. Take that shape
  // first (base64-wrapped or plain), then fall through to the link parser.
  if (looksLikeSingboxConfig(text)) {
    final List<ProxyNode> fromConfig = parseSingboxOutbounds(text)
        .where((ProxyNode n) => !_isPlaceholderNode(n))
        .toList();
    if (fromConfig.isNotEmpty) {
      lastSkippedLinks = SkippedLinks(const <String, int>{});
      return fromConfig;
    }
  }
  final List<ProxyNode> nodes = <ProxyNode>[];
  final Map<String, int> skipped = <String, int>{};
  void note(String line) {
    final int at = line.indexOf('://');
    // Cap the length so a malformed line cannot become the label.
    final String scheme =
        at > 0 && at <= 24 ? line.substring(0, at).toLowerCase() : '?';
    skipped[scheme] = (skipped[scheme] ?? 0) + 1;
  }

  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final ProxyNode? node = parseShareLink(line);
    if (node != null) {
      if (!_isPlaceholderNode(node)) nodes.add(node);
      continue;
    }
    // A single line may itself be base64 that expands to one or more links.
    // Some panels return a MIXED body: a plaintext info node on the first line
    // (its name carries the usage/expiry) followed by a base64 blob holding the
    // real node list. The whole-body decode above only fires when the body has
    // no '://' at all, so that base64 line would otherwise be dropped and the
    // user sees just the one plaintext node ("I can only see one config").
    // Decode per line so the real nodes come through.
    final String? decoded = _decodeBase64Line(line);
    if (decoded != null) {
      for (final String inner in const LineSplitter().convert(decoded)) {
        final String innerLine = inner.trim();
        if (innerLine.isEmpty) continue;
        final ProxyNode? n = parseShareLink(innerLine);
        if (n != null) {
          if (!_isPlaceholderNode(n)) nodes.add(n);
        } else {
          note(innerLine);
        }
      }
      continue;
    }
    note(line);
  }
  lastSkippedLinks = SkippedLinks(skipped);
  return nodes;
}

/// True for the fake "info" node some panels prepend to a subscription to show
/// quota/expiry or a channel link in its name: it points at a placeholder
/// address and is not a real exit, so it must not appear as a selectable
/// config. Covers the obvious loopback/unspecified hosts plus the RFC 5737
/// documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) that
/// Nova's panel uses for its announcement and usage rows.
bool _isPlaceholderNode(ProxyNode node) {
  final String host = node.server.trim();
  const Set<String> placeholders = <String>{'1.1.1.1', '0.0.0.0', '127.0.0.1'};
  if (placeholders.contains(host)) return true;
  return host.startsWith('192.0.2.') ||
      host.startsWith('198.51.100.') ||
      host.startsWith('203.0.113.');
}

/// Try to base64-decode a single subscription line (URL-safe alphabet, missing
/// padding tolerated). Returns the decoded text only if it actually reveals
/// share links (`://`), else null so a non-base64 line is left untouched.
String? _decodeBase64Line(String line) {
  if (line.contains('://')) return null; // already a plaintext link
  try {
    String s = line.replaceAll('-', '+').replaceAll('_', '/');
    final int mod = s.length % 4;
    if (mod != 0) s = s.padRight(s.length + (4 - mod), '=');
    final String decoded = utf8.decode(base64.decode(s));
    return decoded.contains('://') ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Fetches [url] and returns its [NovaCoreConfig], or `null` if it yields no
/// usable nodes. Pass [fetch] to supply a custom transport (tests / mocks).
Future<NovaCoreConfig?> fetchCoreConfig(
  String url, {
  SubscriptionFetcher? fetch,
}) async {
  final String body = await fetchSubscriptionBody(url, fetch: fetch);
  return NovaCoreConfig.fromNodes(parseSubscriptionBody(body));
}

/// Fetches the raw subscription body text (before parsing), so callers that need
/// to persist the exact bytes the panel served can do so. Mirrors the transport
/// choice [fetchCoreConfig] used to make inline: prefer the supplied fetcher (the
/// relay or a test mock), but for a bare-IP "no domain" host fall back to a
/// direct fetch that accepts the self-signed certificate.
Future<String> fetchSubscriptionBody(
  String url, {
  SubscriptionFetcher? fetch,
}) async {
  final Uri uri = Uri.parse(url);
  final bool bareIp = _isBareIpHost(uri);
  String? body;
  if (fetch != null) {
    try {
      body = await fetch(uri);
    } catch (_) {
      if (!bareIp) rethrow; // a real relay/transport error for a domain host
    }
  }
  return body ?? await _httpFetch(uri, insecure: bareIp);
}

/// Whether [uri]'s host is a bare IP literal (IPv4/IPv6) rather than a domain.
/// A self-signed Nova node is always reached by IP, so this cleanly identifies
/// the "no domain" case without a separate flag.
bool _isBareIpHost(Uri uri) {
  return InternetAddress.tryParse(uri.host) != null;
}

/// If [body] isn't already plaintext links, try to base64-decode it (tolerating
/// URL-safe alphabet, embedded newlines, and missing padding). Returns the
/// original body if decoding doesn't reveal links.
String _maybeBase64Decode(String body) {
  if (body.contains('://')) return body;
  try {
    String s = body
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    final int mod = s.length % 4;
    if (mod != 0) s = s.padRight(s.length + (4 - mod), '=');
    final String decoded = utf8.decode(base64.decode(s));
    return decoded.contains('://') ? decoded : body;
  } catch (_) {
    return body;
  }
}

/// Extracts the `colo=XXX` datacenter code from a Cloudflare `/cdn-cgi/trace`
/// body, uppercased, or `''` if absent.
String parseColo(String traceBody) {
  for (final String raw in const LineSplitter().convert(traceBody)) {
    final String line = raw.trim();
    if (line.startsWith('colo=')) return line.substring(5).trim().toUpperCase();
  }
  return '';
}

/// Looks up the client's current Cloudflare edge datacenter (the exit colo),
/// matching how the worker derives the flag it stamps on every node: once per
/// request, from the serving edge. Best-effort, returns `''` on any failure.
Future<String> fetchExitColo({SubscriptionFetcher? fetch}) async {
  try {
    final String body = await (fetch ?? _httpFetch)(
      Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'),
    );
    return parseColo(body);
  } catch (_) {
    return '';
  }
}

/// Resolves the node a [profile] should actually connect through.
///
/// This is the piece that lets the tunnel connect to a **subscription**: a
/// subscription profile carries its source URL in [ProxyProfile.subscriptionUrl]
/// and an empty [ProxyProfile.uri], so parsing `uri` as a single link (the old
/// behaviour) always failed with "Unsupported or invalid profile link". Here we
/// fetch the subscription, expand it, and return a real connectable node (the
/// template, which carries the shared auth/TLS/transport fields). A single-link
/// profile still just parses its `uri`.
///
/// Returns `null` only when nothing usable could be resolved.
Future<ProxyNode?> resolveProfileNode(
  ProxyProfile profile, {
  SubscriptionFetcher? fetch,
}) async {
  final String raw = _profilePayload(profile);
  if (raw.isEmpty) return null;
  if (_isHttpUrl(raw)) {
    final NovaCoreConfig? core = await fetchCoreConfig(raw, fetch: fetch);
    return core?.template;
  }
  return parseShareLink(raw);
}

/// The text a profile actually carries, preferring the subscription field but
/// falling back to [ProxyProfile.uri]. Either one may legitimately hold the URL
/// or the share link depending on how the profile was added.
String _profilePayload(ProxyProfile profile) {
  final String sub = (profile.subscriptionUrl ?? '').trim();
  if (sub.isNotEmpty) return sub;
  return profile.uri.trim();
}

/// An actionable reason a [profile] resolved to zero nodes, so the UI can say
/// what to fix instead of a blanket "Unsupported or invalid profile link".
String emptyResolveMessage(ProxyProfile profile) {
  final String raw = _profilePayload(profile);
  if (raw.isEmpty) {
    return 'This profile is empty. Add your Nova subscription URL or a '
        'vless:// link.';
  }
  if (_isHttpUrl(raw)) {
    return 'That subscription returned no nodes. Make sure the URL is your '
        'Nova /sub link (it should return a node list, not a web page).';
  }
  return "That link isn't a supported vless://, trojan://, or ss:// link.";
}

/// Whether [raw] is a fetchable subscription URL (vs an inline share link). This
/// is decided by the content, not the profile's declared kind, so a `vless://`
/// link tagged "Subscription" or an `https://…/sub` URL tagged "VLESS" both
/// still resolve instead of failing as "Unsupported or invalid profile link".
bool _isHttpUrl(String raw) {
  final String l = raw.toLowerCase();
  return l.startsWith('http://') || l.startsWith('https://');
}

/// Resolves every candidate node for a [profile], not just one: a subscription
/// expands to its whole node list so the core can auto-pick the fastest via a
/// `urltest`, and a single-link profile yields a one-element list. Returns an
/// empty list when nothing usable resolves.
///
/// Real Nova nodes carry a uuid; the free-notice banner is dropped when any
/// real node exists so it never wastes a slot in the auto-selector.
/// Session cache of resolved subscription nodes, keyed by the payload URL. Keeps
/// re-opening the node list (or reconnecting) from re-fetching the subscription
/// — which is slow when it has to go through the tunnel. Cleared on app restart;
/// [clearSubscriptionCache] drops it for a manual refresh.
final Map<String, List<ProxyNode>> _nodeCache = <String, List<ProxyNode>>{};

void clearSubscriptionCache() => _nodeCache.clear();

/// Persists the last good raw body of each subscription across app restarts.
///
/// This is what keeps a user from being stranded: when workers.dev is blocked
/// and the sub can't be refreshed, the panel URL fails, but the servers it last
/// handed out are still perfectly usable (they connect to clean Cloudflare IPs,
/// not the blocked domain). So the last successful body is saved, and a failed
/// refresh serves it instead of wiping the list. Wired to disk at startup; left
/// null in tests (which drive their own fetcher), where it is simply skipped.
abstract class SubscriptionBodyStore {
  Future<String?> load(String url);
  Future<void> save(String url, String body);
}

SubscriptionBodyStore? subscriptionBodyStore;

/// True when the most recent [resolveProfileNodes] served nodes from the saved
/// body because the live refresh failed. Read right after the call (like
/// [lastSkippedLinks]) so the UI can say "showing saved servers" without turning
/// a refresh failure into a fatal, list-wiping error.
bool lastResolveWasStale = false;

/// Turns a fetched subscription [body] into the real, connectable nodes: keep
/// every node that carries a credential, dropping only the credential-less
/// info/banner node some panels prepend. Falls back to all nodes if that filter
/// would empty the list.
List<ProxyNode> _expandSubscriptionBody(String body) {
  final NovaCoreConfig? core =
      NovaCoreConfig.fromNodes(parseSubscriptionBody(body));
  if (core == null) return const <ProxyNode>[];
  bool hasCredential(ProxyNode n) =>
      (n.uuid ?? '').isNotEmpty ||
      (n.password ?? '').isNotEmpty ||
      (n.method ?? '').isNotEmpty ||
      (n.awgConf ?? '').isNotEmpty; // AmneziaWG auth is keys, not uuid/password
  final List<ProxyNode> real = core.nodes.where(hasCredential).toList();
  return real.isNotEmpty ? real : core.nodes;
}

/// Best-effort read of a saved subscription body; never throws (a broken store
/// must not turn into a failure to resolve).
Future<String?> _loadSavedBody(String url) async {
  try {
    return await subscriptionBodyStore?.load(url);
  } catch (_) {
    return null;
  }
}

/// Best-effort persist of a freshly-fetched body; never throws.
Future<void> _saveBody(String url, String body) async {
  try {
    await subscriptionBodyStore?.save(url, body);
  } catch (_) {
    // A failed save just means the next blocked refresh has nothing to fall
    // back to; it must never break the resolve that is currently succeeding.
  }
}

/// The nodes for [profile] that are already available with NO network at all:
/// the in-memory session cache, or the persisted last-good body. Returns empty
/// when nothing is saved yet (a genuine first run).
///
/// This is what lets the server list appear instantly instead of sitting on a
/// spinner for the ~40s a filtered subscription URL takes to time out. The list
/// shows these first, then refreshes live in the background.
/// Applies the profile's own rules to a resolved list.
///
/// Today that is only [ProxyProfile.encryptedOnly], which the free list Nova
/// ships sets: someone who installs the app and presses Connect must not be put
/// on a plaintext tunnel, whatever the upstream list happens to contain that
/// day. A subscription the user added themselves is never filtered.
///
/// Servers that are merely DOWN are not filtered here on purpose. Hiding them
/// is a view decision made from the last measurement (see the node list), not a
/// property of the subscription: filtering them out at this level means the
/// next sweep only ever sees the survivors, and a run of bad luck ratchets a
/// list down and never lets it recover.
List<ProxyNode> applyProfileFilters(ProxyProfile profile, List<ProxyNode> nodes) {
  if (!profile.encryptedOnly) return nodes;
  return nodes.where((ProxyNode n) => n.isEncrypted).toList();
}

Future<List<ProxyNode>> cachedProfileNodes(ProxyProfile profile) async =>
    applyProfileFilters(profile, await _cachedProfileNodes(profile));

Future<List<ProxyNode>> resolveProfileNodes(
  ProxyProfile profile, {
  SubscriptionFetcher? fetch,
}) async =>
    applyProfileFilters(
        profile, await _resolveProfileNodes(profile, fetch: fetch));

Future<List<ProxyNode>> _cachedProfileNodes(ProxyProfile profile) async {
  final String raw = _profilePayload(profile);
  if (raw.isEmpty || !_isHttpUrl(raw)) return const <ProxyNode>[];
  if (_nodeCache[raw] != null) return _nodeCache[raw]!;
  final String? saved = await _loadSavedBody(raw);
  if (saved == null) return const <ProxyNode>[];
  return _expandSubscriptionBody(saved);
}

Future<List<ProxyNode>> _resolveProfileNodes(
  ProxyProfile profile, {
  SubscriptionFetcher? fetch,
}) async {
  lastResolveWasStale = false;
  final String raw = _profilePayload(profile);
  if (raw.isEmpty) return const <ProxyNode>[];
  // A SOCKS / HTTP proxy is a single link that starts with http(s)://socks://,
  // so match it before the http-url fetch would treat it as a subscription.
  if (profile.kind == ProxyKind.socks || profile.kind == ProxyKind.http) {
    final ProxyNode? n = parseShareLink(raw);
    return n == null ? const <ProxyNode>[] : <ProxyNode>[n];
  }
  if (_isHttpUrl(raw)) {
    // Only the real network path is cached (tests pass a custom fetch).
    if (fetch == null && _nodeCache[raw] != null) return _nodeCache[raw]!;
    String body;
    try {
      body = await fetchSubscriptionBody(raw, fetch: fetch);
    } catch (e) {
      // The live refresh failed. This is the workers.dev-blocked case: the panel
      // URL is unreachable, but the servers it last handed out still work (they
      // connect to clean IPs, not the blocked domain). Serve the saved body so
      // the user keeps their list and can still connect, instead of wiping it.
      // Persistence is store-backed (null in tests), so this is fetch-agnostic:
      // the relay path benefits from the same fallback.
      final String? saved = await _loadSavedBody(raw);
      if (saved == null) rethrow; // nothing saved yet: a genuine first-run error
      lastResolveWasStale = true;
      // Deliberately NOT written to the session cache: a stale result must not
      // stick, so the next open (or connect) retries the live fetch and picks up
      // the fresh list the moment connectivity comes back.
      return _expandSubscriptionBody(saved);
    }
    // Keep every real node, whatever its protocol (a mixed sub has Trojan / SS /
    // Hysteria2 / TUIC too), dropping only the credential-less info/banner node.
    final List<ProxyNode> out = _expandSubscriptionBody(body);
    if (out.isNotEmpty) {
      // The session cache is test-sensitive, so it stays gated on the real path.
      if (fetch == null) _nodeCache[raw] = out;
      // Save the freshly-fetched body so a future blocked refresh has it. The
      // store is null in tests, so this is a no-op there whatever the fetcher.
      await _saveBody(raw, body);
    }
    return out;
  }
  // A pasted AmneziaWG / WireGuard `.conf` is a single multi-line node (not a
  // list of links), so handle it before the line-splitting body parser.
  if (AwgConfig.looksLikeConf(raw)) {
    try {
      return <ProxyNode>[ProxyNode.fromAwgConf(raw, name: profile.name)];
    } catch (_) {
      return const <ProxyNode>[];
    }
  }
  // Inline payload: one link, or several (a base64 / multi-line body embedded in
  // the profile, e.g. a no-domain VPS whose self-signed cert makes a live /sub
  // fetch impractical). Parse them all so the auto-selector still has a pool.
  final List<ProxyNode> inline = parseSubscriptionBody(raw);
  if (inline.isNotEmpty) return inline;
  final ProxyNode? node = parseShareLink(raw);
  return node == null ? const <ProxyNode>[] : <ProxyNode>[node];
}

/// Default transport: a plain GET with a non-browser User-Agent so the worker
/// returns raw config text (a browser UA gets the HTML hub instead).
///
/// Retries once on a network error. A first attempt on a slow or throttled link
/// (common in Iran) often times out where a second, warmed-up connection gets
/// through. A real HTTP status (non-200) is not retried, since that won't
/// change on a second try.
Future<String> _httpFetch(Uri url, {bool insecure = false}) async {
  // Fast path: a direct fetch, retried once for a transient hiccup. A bad HTTP
  // status means we reached the server (not a block), so surface it as-is.
  for (int attempt = 0; attempt < 2; attempt++) {
    try {
      return await _httpFetchOnce(url, insecure: insecure);
    } on HttpException {
      rethrow;
    } catch (_) {
      if (attempt >= 1) break;
    }
  }
  // A bare-IP self-signed node is reached directly; the SNI-fragment fallback is
  // for a domain being SNI-blocked, which doesn't apply, so don't attempt it
  // (and it would re-validate the cert anyway).
  if (insecure) return await _httpFetchOnce(url, insecure: true);
  // The direct fetch failed at the connection level, which is exactly what a
  // plaintext-SNI block on workers.dev looks like from Iran. Retry through a
  // local fragment proxy that splits the TLS ClientHello so the censor can't
  // match the SNI in a single packet (the same anti-DPI trick the tunnel uses).
  FragmentProxy? fp;
  try {
    fp = await FragmentProxy.start();
    return await _httpFetchOnce(url, proxyAuthority: fp.authority);
  } finally {
    await fp?.stop();
  }
}

Future<String> _httpFetchOnce(Uri url,
    {String? proxyAuthority, bool insecure = false}) async {
  final HttpClient client = HttpClient()
    // Kept short: on a filtered subscription URL the connect just hangs, and the
    // whole point is to fail fast through to the SNI-fragment fallback (and, if
    // that fails too, to the saved list) rather than sit on a spinner.
    ..connectionTimeout = const Duration(seconds: 8);
  if (insecure) {
    // Accept the node's self-signed certificate (the "no domain" case). Scoped
    // to this one request; the default validating client is used everywhere else.
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  }
  if (proxyAuthority != null) {
    // Route this request through the loopback fragment proxy: HttpClient issues
    // CONNECT <host>:443 to it, then does TLS end to end through the tunnel, so
    // the origin certificate still validates against the real host.
    client.findProxy = (_) => 'PROXY $proxyAuthority';
  }
  try {
    final HttpClientRequest req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'NovaClient');
    final HttpClientResponse resp =
        await req.close().timeout(const Duration(seconds: 12));
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('Subscription HTTP ${resp.statusCode}', uri: url);
    }
    final SubInfo? info =
        SubInfo.parse(resp.headers.value('subscription-userinfo'));
    if (info != null) {
      _subInfoCache[url.toString()] = info;
      unawaited(subInfoStore?.save(url.toString(), info));
    }
    return await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 12));
  } finally {
    client.close(force: true);
  }
}
