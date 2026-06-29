import 'dart:convert';

import 'proxy_node.dart';

/// Routing behaviour, mapping onto the controls on the Routing screen.
enum SingboxMode { rule, global, direct }

class SingboxRouteOptions {
  const SingboxRouteOptions({
    this.mode = SingboxMode.rule,
    this.blockAds = true,
    this.bypassIran = true,
    this.bypassLan = true,
    this.dns = '',
  });

  final SingboxMode mode;
  final bool blockAds;
  final bool bypassIran;
  final bool bypassLan;

  /// The upstream resolver IP the remote DNS server points at (DoH). Empty
  /// means Nova's default (Cloudflare 1.1.1.1). Matches the native app's DNS
  /// picker: '' / 1.1.1.1 / 8.8.8.8 / 9.9.9.9 / 94.140.14.14.
  final String dns;
}

/// Builds a sing-box configuration document from a [ProxyNode].
///
/// Targets the sing-box 1.8–1.11 schema (TUN inbound + DNS + rule-based route
/// with remote rule-sets). This is exactly the JSON the native core consumes;
/// keeping it in Dart means it is unit-tested and shared across every platform
/// host, with the native side only responsible for running it on the TUN fd.
class SingboxConfig {
  const SingboxConfig._();

  // Iran + ad rule-sets — the de-facto standard sources for sing-box on Iranian
  // networks (used when the matching routing toggles are on).
  static const String _adsRuleSet =
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs';
  static const String _geoipIr =
      'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs';
  static const String _geositeIr =
      'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs';

  /// Returns the config as a pretty-printed JSON string.
  static String build(
    ProxyNode node, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    return const JsonEncoder.withIndent('  ').convert(buildMap(node, options: options));
  }

  /// Returns the config as a map (useful for tests / further mutation).
  static Map<String, dynamic> buildMap(
    ProxyNode node, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    return <String, dynamic>{
      'log': <String, dynamic>{'level': 'warn', 'timestamp': true},
      'dns': _dns(options, directDomains: _directDomains(<ProxyNode>[node])),
      'inbounds': <Map<String, dynamic>>[_tunInbound()],
      'outbounds': <Map<String, dynamic>>[
        _outbound(node),
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        <String, dynamic>{'type': 'dns', 'tag': 'dns-out'},
      ],
      'route': _route(options),
    };
  }

  /// The most nodes we ever put behind the auto-selector. The iOS Network
  /// Extension runs under a hard ~50 MB memory cap, and every extra outbound is
  /// a live dialer it has to hold; a few dozen of the subscription's nodes is
  /// plenty to find a fast one without risking the extension being killed.
  static const int kMaxAutoNodes = 24;

  /// Like [build], but for a whole subscription: wires every node behind a
  /// `urltest` tagged `proxy` so the core continuously measures latency and
  /// routes through the fastest one. Falls back to the single-node [build] when
  /// only one node is given. The rest of the document (route, DNS) is identical
  /// because the auto-selector keeps the `proxy` tag the rest of the config
  /// already targets.
  static String buildMulti(
    List<ProxyNode> nodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    return const JsonEncoder.withIndent('  ')
        .convert(buildMultiMap(nodes, options: options));
  }

  static Map<String, dynamic> buildMultiMap(
    List<ProxyNode> nodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    final List<ProxyNode> picked = _dedupe(nodes).take(kMaxAutoNodes).toList();
    if (picked.length <= 1) {
      return buildMap(
        picked.isEmpty ? nodes.first : picked.first,
        options: options,
      );
    }
    final List<Map<String, dynamic>> nodeOutbounds = <Map<String, dynamic>>[];
    final List<String> tags = <String>[];
    for (int i = 0; i < picked.length; i++) {
      final String tag = 'node-$i';
      tags.add(tag);
      nodeOutbounds.add(_outbound(picked[i], tag: tag));
    }
    return <String, dynamic>{
      'log': <String, dynamic>{'level': 'warn', 'timestamp': true},
      'dns': _dns(options, directDomains: _directDomains(picked)),
      'inbounds': <Map<String, dynamic>>[_tunInbound()],
      'outbounds': <Map<String, dynamic>>[
        // Auto-pick the lowest-latency node and keep checking, without tearing
        // down live connections when it switches (smoother downloads).
        <String, dynamic>{
          'type': 'urltest',
          'tag': 'proxy',
          'outbounds': tags,
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '2m0s',
          'tolerance': 50,
          'idle_timeout': '30m0s',
          'interrupt_exist_connections': false,
        },
        ...nodeOutbounds,
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        <String, dynamic>{'type': 'dns', 'tag': 'dns-out'},
      ],
      'route': _route(options),
    };
  }

  /// Drops duplicate endpoints (same server:port:path) so the auto-selector
  /// isn't full of identical hops, keeping the node budget for real variety.
  static List<ProxyNode> _dedupe(List<ProxyNode> nodes) {
    final Set<String> seen = <String>{};
    final List<ProxyNode> out = <ProxyNode>[];
    for (final ProxyNode n in nodes) {
      final String key = '${n.server}:${n.port}:${n.wsPath ?? ''}';
      if (seen.add(key)) out.add(n);
    }
    return out;
  }

  static Map<String, dynamic> _tunInbound() => <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'nova-tun',
        'inet4_address': '172.19.0.1/30',
        'mtu': 9000,
        'auto_route': true,
        'strict_route': true,
        'stack': 'system',
        'sniff': true,
        'sniff_override_destination': false,
      };

  static Map<String, dynamic> _dns(
    SingboxRouteOptions o, {
    Iterable<String> directDomains = const <String>[],
  }) {
    // The chosen resolver (IP-based DoH, so it needs no bootstrap resolver),
    // routed through the proxy. Empty = Nova default (Cloudflare).
    final String remote = o.dns.isEmpty ? '1.1.1.1' : o.dns;
    final List<String> direct = directDomains.toList();
    return <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'remote',
          'address': 'https://$remote/dns-query',
          'detour': 'proxy',
        },
        <String, dynamic>{
          'tag': 'local',
          'address': 'https://223.5.5.5/dns-query',
          'detour': 'direct',
        },
        <String, dynamic>{'tag': 'block', 'address': 'rcode://success'},
      ],
      'rules': <Map<String, dynamic>>[
        // The proxy's own server domains MUST resolve directly. Otherwise
        // resolving them falls through to `remote`, which is reached *through*
        // the proxy, which needs them resolved first — sing-box aborts startup
        // with "DNS query loopback in transport[remote]" and nothing connects.
        if (direct.isNotEmpty)
          <String, dynamic>{'domain': direct, 'server': 'local'},
        // Only reference rule-sets that _route() actually defines, otherwise
        // sing-box rejects the config for an undefined rule_set reference.
        if (o.blockAds && o.mode != SingboxMode.direct)
          <String, dynamic>{'rule_set': 'geosite-ads', 'server': 'block'},
        if (o.bypassIran && o.mode == SingboxMode.rule)
          <String, dynamic>{'rule_set': 'geosite-ir', 'server': 'local'},
      ],
      'final': o.mode == SingboxMode.direct ? 'local' : 'remote',
      'strategy': 'prefer_ipv4',
    };
  }

  static Map<String, dynamic> _outbound(ProxyNode n, {String tag = 'proxy'}) {
    final Map<String, dynamic> o = <String, dynamic>{
      'type': n.protocol.singboxType,
      'tag': tag,
      'server': n.server,
      'server_port': n.port,
    };
    switch (n.protocol) {
      case NodeProtocol.vless:
        o['uuid'] = n.uuid;
        if (n.flow != null) o['flow'] = n.flow;
      case NodeProtocol.trojan:
        o['password'] = n.password;
      case NodeProtocol.shadowsocks:
        o['method'] = n.method;
        o['password'] = n.password;
    }
    if (n.tls) o['tls'] = _tls(n);
    final Map<String, dynamic>? transport = _transport(n);
    if (transport != null) o['transport'] = transport;
    return o;
  }

  static Map<String, dynamic> _tls(ProxyNode n) {
    return <String, dynamic>{
      'enabled': true,
      'server_name': n.sni ?? n.server,
      if (n.allowInsecure) 'insecure': true,
      if (n.alpn.isNotEmpty) 'alpn': n.alpn,
      if (n.fingerprint != null && n.fingerprint!.isNotEmpty)
        'utls': <String, dynamic>{'enabled': true, 'fingerprint': n.fingerprint},
    };
  }

  static Map<String, dynamic>? _transport(ProxyNode n) {
    switch (n.network) {
      case 'ws':
        return <String, dynamic>{
          'type': 'ws',
          'path': n.wsPath ?? '/',
          if (n.wsHost != null && n.wsHost!.isNotEmpty)
            'headers': <String, dynamic>{'Host': n.wsHost},
        };
      case 'grpc':
        return <String, dynamic>{
          'type': 'grpc',
          'service_name': n.grpcServiceName ?? '',
        };
      default:
        return null;
    }
  }

  static Map<String, dynamic> _route(SingboxRouteOptions o) {
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[
      <String, dynamic>{'protocol': 'dns', 'outbound': 'dns-out'},
    ];
    final List<Map<String, dynamic>> ruleSets = <Map<String, dynamic>>[];

    if (o.mode == SingboxMode.rule) {
      if (o.bypassLan) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds) {
        rules.add(<String, dynamic>{'rule_set': 'geosite-ads', 'outbound': 'block'});
        ruleSets.add(_remoteRuleSet('geosite-ads', _adsRuleSet));
      }
      if (o.bypassIran) {
        rules.add(<String, dynamic>{
          'rule_set': <String>['geoip-ir', 'geosite-ir'],
          'outbound': 'direct',
        });
        ruleSets.add(_remoteRuleSet('geoip-ir', _geoipIr));
        ruleSets.add(_remoteRuleSet('geosite-ir', _geositeIr));
      }
    } else if (o.mode == SingboxMode.global) {
      if (o.bypassLan) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds) {
        rules.add(<String, dynamic>{'rule_set': 'geosite-ads', 'outbound': 'block'});
        ruleSets.add(_remoteRuleSet('geosite-ads', _adsRuleSet));
      }
    }

    final String finalOutbound =
        o.mode == SingboxMode.direct ? 'direct' : 'proxy';

    return <String, dynamic>{
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': finalOutbound,
      'auto_detect_interface': true,
    };
  }

  static Map<String, dynamic> _remoteRuleSet(String tag, String url) =>
      <String, dynamic>{
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': url,
        // Pull rule-sets through the tunnel, not `direct`: the hosts
        // (githubusercontent) are blocked on some ISPs, and the proxy exit
        // (Cloudflare) reaches them reliably once it is up.
        'download_detour': 'proxy',
      };

  /// The server/SNI/WS-host domains the proxy outbounds dial. These must resolve
  /// via the direct DNS so bringing the proxy up doesn't depend on a resolver
  /// that is itself reached through the proxy (the startup DNS loop). IP
  /// literals are skipped — they need no resolution.
  static List<String> _directDomains(List<ProxyNode> nodes) {
    final Set<String> out = <String>{};
    for (final ProxyNode n in nodes) {
      for (final String? d in <String?>[n.server, n.sni, n.wsHost]) {
        if (d != null && d.isNotEmpty && !_isIpLiteral(d)) out.add(d);
      }
    }
    return out.toList();
  }

  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true; // IPv6
    final List<String> parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((String p) {
      final int? v = int.tryParse(p);
      return v != null && v >= 0 && v <= 255;
    });
  }
}
