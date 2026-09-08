import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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
      (needsAddress(n) || InternetAddress.tryParse(n.server) == null) &&
      (needsAddress(n) || n.server.contains('.')) &&
      kCloudflareTlsPorts.contains(n.port);

  /// Addresses that mean "this node has no address yet, fill one in".
  static const Set<String> kPlaceholderAddresses = <String>{
    '127.0.0.1',
    '0.0.0.0',
    '::',
    '::1',
  };

  /// Whether this node was published WITHOUT a usable address, expecting the
  /// device to supply one from its own scan.
  ///
  /// This is the strongest form of the defence. A published list that contains
  /// real addresses can be fetched once and blocked wholesale, which is what
  /// kills the free servers every couple of days. A list published with
  /// placeholders gives a censor nothing to block: every user's copy is
  /// addressed from their own Radar scan, so the traffic is spread across as
  /// many addresses as there are users rather than concentrated on a handful
  /// that everyone shares.
  ///
  /// A TLS name is REQUIRED for one of these, and is what tells a placeholder
  /// apart from someone's genuine local proxy on 127.0.0.1. Without it there is
  /// nothing to put in the handshake (the address is not a name), so such a
  /// node is not treated as a placeholder and is left alone rather than being
  /// rewritten into something that cannot work.
  static bool needsAddress(ProxyNode n) =>
      kPlaceholderAddresses.contains(n.server.trim()) &&
      ((n.sni ?? '').trim().isNotEmpty || (n.wsHost ?? '').trim().isNotEmpty);

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
      // A placeholder has nothing to resolve, and needs no proof: it was
      // published with no address precisely so this device would supply one.
      if (!couldBeFronted(n) ||
          (!needsAddress(n) &&
              !await _behindCloudflare(n.server, lookupTimeout))) {
        out.add(n);
        continue;
      }
      out.add(n.copyWith(
        server: ip.ip,
        port: ip.port,
        // Whatever the config already said wins; only fill in what is missing.
        // A placeholder is not a name, so it must never become the TLS name:
        // needsAddress() guarantees one of these two was published.
        sni: n.sni ?? (needsAddress(n) ? n.wsHost : n.server),
        wsHost: n.wsHost ?? (needsAddress(n) ? n.sni : n.server),
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
          (!needsAddress(n) &&
              !await _behindCloudflare(n.server, lookupTimeout))) {
        out.add(n);
        continue;
      }
      final CleanIp ip = ips[rnd.nextInt(ips.length)];
      out.add(n.copyWith(
        server: ip.ip,
        port: ip.port,
        // Whatever the config already said wins; only fill in what is missing.
        // A placeholder is not a name, so it must never become the TLS name:
        // needsAddress() guarantees one of these two was published.
        sni: n.sni ?? (needsAddress(n) ? n.wsHost : n.server),
        wsHost: n.wsHost ?? (needsAddress(n) ? n.sni : n.server),
      ));
      rewritten++;
    }
    if (rewritten > 0) {
      NovaLog.instance.write('Dialling $rewritten Cloudflare servers through '
          '${ips.length} scanned addresses');
    }
    return out;
  }

  /// Whether a profile's servers may be re-addressed through scanned addresses.
  ///
  /// Two gates, and they answer to different people. [hardenTls] is the
  /// profile's own setting, so a subscription the user added is fronted or not
  /// on its own terms. [boostFreeList] is the Radar switch, and it governs the
  /// free list alone: that list is Nova's, published world-readable, and
  /// re-addressing it is the one case where the app changes what someone's
  /// servers dial without their provider saying so.
  ///
  /// Off means off. The free list then goes out on the addresses it was
  /// published with, and no scan is started on its behalf. An opt-out that
  /// still re-addresses is not an opt-out: someone who suspects this of
  /// breaking their connection has no way to find out while the switch only
  /// changes what a list displays.
  static bool mayReAddress({
    required bool hardenTls,
    required bool isFreeList,
    required bool boostFreeList,
  }) {
    if (!hardenTls) return false;
    if (isFreeList && !boostFreeList) return false;
    return true;
  }

  /// Drops nodes that are still placeholders, i.e. published with no address
  /// and not given one by a scan.
  ///
  /// Dialling 127.0.0.1 reaches this device, not a server, so an unaddressed
  /// node cannot work and must not sit in the pool pretending it might. When
  /// this empties the list the honest outcome is "run a scan", which the free
  /// list screen offers, not a connection attempt that fails in a way nobody
  /// can read.
  static List<ProxyNode> dropUnaddressed(List<ProxyNode> nodes) {
    if (!nodes.any(needsAddress)) return nodes;
    final List<ProxyNode> out =
        nodes.where((ProxyNode n) => !needsAddress(n)).toList();
    NovaLog.instance.write(
        'Left out ${nodes.length - out.length} servers that have no address '
        'yet; run a Radar scan to use them');
    return out;
  }

  /// Fronts [nodes] with the best this device has: the scanned [pool] when a
  /// scan has kept one, otherwise the [single] stored address.
  ///
  /// The pool is preferred wherever it exists, for the reason [applySpread]
  /// gives: one address for a whole list is a single point of failure and a
  /// single thing for a filter to notice. The connect path used to take that
  /// road for everyone, because it read only the single stored address and the
  /// pool a scan keeps was read by nothing but the free-list screen. A scan's
  /// work now reaches the traffic and not just the list.
  ///
  /// Returns [nodes] untouched when no scan has produced anything yet. Never
  /// starts a scan: picking between what already exists is the whole job, and
  /// the caller decides whether an empty-handed device is worth one.
  static Future<List<ProxyNode>> applyAvailable(
    List<ProxyNode> nodes, {
    required List<CleanIp> pool,
    required CleanIp? single,
    Duration lookupTimeout = const Duration(seconds: 4),
    int? seed,
  }) async {
    if (pool.isNotEmpty) {
      return applySpread(nodes, pool, lookupTimeout: lookupTimeout, seed: seed);
    }
    if (single != null) {
      return apply(nodes, single, lookupTimeout: lookupTimeout);
    }
    return nodes;
  }

  /// Seeds the resolve cache, so a test can exercise the rewriting without a DNS
  /// lookup and without a network.
  ///
  /// [apply] and [applySpread] consult this same cache before resolving, so a
  /// host named here is treated as settled fact. Production code never calls
  /// this.
  @visibleForTesting
  static void rememberLookupsForTests(Map<String, bool> hosts) =>
      _isCloudflare.addAll(hosts);

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
