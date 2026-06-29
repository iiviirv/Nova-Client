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
import 'singbox/proxy_node.dart';
import 'singbox/share_link.dart';

/// Fetches the raw body of a subscription URL. Injectable so tests don't hit
/// the network.
typedef SubscriptionFetcher = Future<String> Function(Uri url);

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

/// Parses a subscription body (base64 or plaintext newline-separated links)
/// into nodes, skipping anything that doesn't parse.
List<ProxyNode> parseSubscriptionBody(String body) {
  final String text = _maybeBase64Decode(body.trim());
  final List<ProxyNode> nodes = <ProxyNode>[];
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    final ProxyNode? node = parseShareLink(line);
    if (node != null) nodes.add(node);
  }
  return nodes;
}

/// Fetches [url] and returns its [NovaCoreConfig], or `null` if it yields no
/// usable nodes. Pass [fetch] to supply a custom transport (tests / mocks).
Future<NovaCoreConfig?> fetchCoreConfig(
  String url, {
  SubscriptionFetcher? fetch,
}) async {
  final String body = await (fetch ?? _httpFetch)(Uri.parse(url));
  return NovaCoreConfig.fromNodes(parseSubscriptionBody(body));
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
  if (profile.isSubscription || (profile.subscriptionUrl ?? '').isNotEmpty) {
    final String url = (profile.subscriptionUrl ?? '').trim();
    if (url.isEmpty) return null;
    final NovaCoreConfig? core = await fetchCoreConfig(url, fetch: fetch);
    return core?.template;
  }
  final String trimmed = profile.uri.trim();
  if (trimmed.isEmpty) return null;
  return parseShareLink(trimmed);
}

/// Default transport: a plain GET with a non-browser User-Agent so the worker
/// returns raw config text (a browser UA gets the HTML hub instead).
Future<String> _httpFetch(Uri url) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final HttpClientRequest req = await client.getUrl(url);
    req.headers.set(HttpHeaders.userAgentHeader, 'NovaClient');
    final HttpClientResponse resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpException('Subscription HTTP ${resp.statusCode}', uri: url);
    }
    return await resp.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}
