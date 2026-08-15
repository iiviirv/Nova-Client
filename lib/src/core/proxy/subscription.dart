// Subscription support: fetch a Nova Proxy `/sub` link, expand it into nodes,
// and derive the "core config" (the template + worker host) the rest of the app
// reads from.
//
// This is the missing piece behind the feedback that the client must read from
// the core: a Nova subscription is a base64 (or plaintext) list of `vless://`
// links that all share one template (uuid/host/sni/fp/path); only the address
// and name differ. We parse them, keep one as the template, and let the Radar
// stamp clean IPs into it.

import 'dart:convert';
import 'dart:io';

import '../models/proxy_profile.dart';
import 'fragment_proxy.dart';
import 'singbox/awg_config.dart';
import 'singbox/proxy_node.dart';
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
  final Uri uri = Uri.parse(url);
  // A subscription served straight off a bare IP is the "no domain" Nova node:
  // it presents a self-signed certificate, so the relay (whose worker exit
  // validates TLS and returns 502) and the default validating client both fail
  // on it. Such a node also isn't domain-blocked, so it never needs the
  // censorship relay. So: prefer the supplied fetcher (the relay, or a test
  // mock), but for a bare-IP host fall back to a direct fetch that accepts the
  // self-signed cert, exactly as the tunnel links already do with
  // allowInsecure=1. A domain host keeps the normal path and surfaces relay
  // errors as before.
  final bool bareIp = _isBareIpHost(uri);
  String? body;
  if (fetch != null) {
    try {
      body = await fetch(uri);
    } catch (_) {
      if (!bareIp) rethrow; // a real relay/transport error for a domain host
    }
  }
  body ??= await _httpFetch(uri, insecure: bareIp);
  return NovaCoreConfig.fromNodes(parseSubscriptionBody(body));
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

Future<List<ProxyNode>> resolveProfileNodes(
  ProxyProfile profile, {
  SubscriptionFetcher? fetch,
}) async {
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
    final NovaCoreConfig? core = await fetchCoreConfig(raw, fetch: fetch);
    if (core == null) return const <ProxyNode>[];
    // Keep every real node, whatever its protocol. Previously this kept only
    // uuid-carrying nodes (VLESS/VMess), which silently dropped every Trojan,
    // Shadowsocks, Hysteria2 and TUIC node in a mixed subscription (a 500-node
    // sub showed as 41). Filter only the credential-less info/banner node some
    // panels prepend; a node with any credential is a real exit.
    bool hasCredential(ProxyNode n) =>
        (n.uuid ?? '').isNotEmpty ||
        (n.password ?? '').isNotEmpty ||
        (n.method ?? '').isNotEmpty ||
        (n.awgConf ?? '').isNotEmpty; // AmneziaWG auth is keys, not uuid/password
    final List<ProxyNode> real =
        core.nodes.where(hasCredential).toList();
    final List<ProxyNode> out = real.isNotEmpty ? real : core.nodes;
    if (fetch == null && out.isNotEmpty) _nodeCache[raw] = out;
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
    ..connectionTimeout = const Duration(seconds: 20);
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
        await req.close().timeout(const Duration(seconds: 25));
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('Subscription HTTP ${resp.statusCode}', uri: url);
    }
    final SubInfo? info =
        SubInfo.parse(resp.headers.value('subscription-userinfo'));
    if (info != null) _subInfoCache[url.toString()] = info;
    return await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 25));
  } finally {
    client.close(force: true);
  }
}
