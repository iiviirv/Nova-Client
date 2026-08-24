import 'dart:io';
import 'dart:math' as math;

import '../logging/nova_log.dart';
import '../proxy/singbox/proxy_node.dart';
import 'clean_ip_store.dart';
import 'cloudflare_ranges.dart';

/// Rewrites Cloudflare-fronted servers to dial a clean address directly.
///
/// A public subscription hands out servers as `sub.example.com:443`, and in
/// Iran that name is filtered within days while the Cloudflare addresses behind
/// it keep working. Dialling the address and sending the name only as the TLS
/// server name keeps the config usable.
///
/// It also turns Nova's SNI-block bypass on for that config, which is the part
/// that matters most. The bypass only applies to a node whose address is
/// already an IP (see ProxyNode.isCleanIpFronted), so before this a
/// domain-addressed config got no fragmentation, no cipher list and no unsafe
/// fingerprint, and died with its domain.
///
/// Nothing here guesses. A server is rewritten only when its name actually
/// resolves into one of Cloudflare's published ranges, so a node hosted
/// anywhere else is left exactly as its provider wrote it.
class CleanIpFronting {
  CleanIpFronting._();

  /// name -> whether it resolves onto Cloudflare, for this run. Subscriptions
  /// repeat the same handful of names across dozens of entries, so this is the
  /// difference between one lookup and fifty.
  static final Map<String, bool> _isCloudflare = <String, bool>{};

  /// True when this node is a candidate: TLS, addressed by name rather than by
  /// number, and on a port Cloudflare terminates TLS on. Cheap checks only; the
  /// lookup happens in [apply].
  static bool couldBeFronted(ProxyNode n) =>
      n.tls &&
      !n.protocol.isEndpoint &&
      InternetAddress.tryParse(n.server) == null &&
      n.server.contains('.') &&
      kCloudflareTlsPorts.contains(n.port);

  /// Applies [ip] to every node in [nodes] that is genuinely behind Cloudflare.
  ///
  /// The name moves to the TLS server name and the Host header if they were not
  /// set explicitly, so the server still sees the request it expects. The tag is
  /// untouched: the row keeps the name the provider gave it.
  static Future<List<ProxyNode>> apply(
    List<ProxyNode> nodes,
    CleanIp ip, {
    Duration lookupTimeout = const Duration(seconds: 4),
  }) async {
    if (nodes.isEmpty) return nodes;
    final List<ProxyNode> out = <ProxyNode>[];
    int rewritten = 0;
    for (final ProxyNode n in nodes) {
      if (!couldBeFronted(n) || !await _behindCloudflare(n.server, lookupTimeout)) {
        out.add(n);
        continue;
      }
      out.add(n.copyWith(
        server: ip.ip,
        port: ip.port,
        // Whatever the config already said wins; only fill in what is missing.
        sni: n.sni ?? n.server,
        wsHost: n.wsHost ?? n.server,
      ));
      rewritten++;
    }
    if (rewritten > 0) {
      NovaLog.instance.write(
          'Dialling $rewritten Cloudflare servers through ${ip.ip}:${ip.port}');
    }
    return out;
  }

  /// Spreads [ips] across [nodes], one address per node, chosen at random.
  ///
  /// One address for a whole list is a single point of failure and a single
  /// thing for a filter to notice: every device that ran a scan ends up dialling
  /// the same IP for every server it has. Handing each server a different
  /// address out of the best few keeps the list working when one of them goes,
  /// and keeps a hundred servers from looking like a hundred connections to one
  /// endpoint.
  ///
  /// [seed] makes the choice reproducible in tests. Falls back to [apply] when
  /// there is only one address, and returns [nodes] untouched when there are
  /// none.
  static Future<List<ProxyNode>> applySpread(
    List<ProxyNode> nodes,
    List<CleanIp> ips, {
    Duration lookupTimeout = const Duration(seconds: 4),
    int? seed,
  }) async {
    if (nodes.isEmpty || ips.isEmpty) return nodes;
    if (ips.length == 1) {
      return apply(nodes, ips.first, lookupTimeout: lookupTimeout);
    }
    final math.Random rnd = math.Random(seed);
    final List<ProxyNode> out = <ProxyNode>[];
    int rewritten = 0;
    for (final ProxyNode n in nodes) {
      if (!couldBeFronted(n) ||
          !await _behindCloudflare(n.server, lookupTimeout)) {
        out.add(n);
        continue;
      }
      final CleanIp ip = ips[rnd.nextInt(ips.length)];
      out.add(n.copyWith(
        server: ip.ip,
        port: ip.port,
        // Whatever the config already said wins; only fill in what is missing.
        sni: n.sni ?? n.server,
        wsHost: n.wsHost ?? n.server,
      ));
      rewritten++;
    }
    if (rewritten > 0) {
      NovaLog.instance.write('Dialling $rewritten Cloudflare servers through '
          '${ips.length} scanned addresses');
    }
    return out;
  }

  static Future<bool> _behindCloudflare(String host, Duration timeout) async {
    final bool? known = _isCloudflare[host];
    if (known != null) return known;
    bool result = false;
    try {
      final List<InternetAddress> found = await InternetAddress.lookup(host)
          .timeout(timeout);
      result = found.any((InternetAddress a) =>
          a.type == InternetAddressType.IPv4 && isCloudflareIp(a.address));
    } catch (_) {
      // Cannot tell, so leave the node alone. A name we failed to resolve is
      // exactly the case where guessing would break a working config.
      result = false;
    }
    _isCloudflare[host] = result;
    return result;
  }

  /// Forgets the lookup cache. Called when the subscription is refreshed, since
  /// a provider can move a server off Cloudflare between updates.
  static void forgetLookups() => _isCloudflare.clear();
}
