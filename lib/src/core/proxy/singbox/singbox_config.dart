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
    this.lean = false,
  });

  final SingboxMode mode;
  final bool blockAds;
  final bool bypassIran;
  final bool bypassLan;

  /// Memory-lean profile for the iOS Network Extension (hard ~50 MB cap):
  /// fewer auto-select nodes, a normal MTU, and no downloaded rule-sets, so the
  /// extension isn't OOM-killed a few seconds into the connection. Desktop and
  /// Android (roomier memory) leave this off and get the full config.
  final bool lean;

  /// The upstream resolver IP the remote DNS server points at (DoH). Empty
  /// means Nova's default (Cloudflare 1.1.1.1). Matches the native app's DNS
  /// picker: '' / 1.1.1.1 / 8.8.8.8 / 9.9.9.9 / 94.140.14.14.
  final String dns;

  SingboxRouteOptions copyWith({bool? lean}) => SingboxRouteOptions(
        mode: mode,
        blockAds: blockAds,
        bypassIran: bypassIran,
        bypassLan: bypassLan,
        dns: dns,
        lean: lean ?? this.lean,
      );
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
      'dns': _dns(options,
          directDomains: <String>{
            ..._directDomains(<ProxyNode>[node]),
            ..._ruleSetHosts,
            ..._directHosts,
          }),
      'inbounds': <Map<String, dynamic>>[_tunInbound(options)],
      'outbounds': <Map<String, dynamic>>[
        _outbound(node),
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        <String, dynamic>{'type': 'dns', 'tag': 'dns-out'},
      ],
      'route': _route(options, blockQuic: !node.protocol.isUdpNative),
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
    // The lean (iOS) path trims the node pool a little to stay under the
    // extension's memory cap, but keeps enough for the urltest to find a fast
    // exit; roomier hosts use the full budget.
    final int cap = options.lean ? 16 : kMaxAutoNodes;
    final List<ProxyNode> picked = _dedupe(nodes).take(cap).toList();
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
      'dns': _dns(options,
          directDomains: <String>{
            ..._directDomains(picked),
            ..._ruleSetHosts,
            ..._directHosts,
          }),
      'inbounds': <Map<String, dynamic>>[_tunInbound(options)],
      'outbounds': <Map<String, dynamic>>[
        // Auto-pick a fast node, then STICK to it. A low tolerance made the core
        // hop between IPs the moment another node measured a few ms faster, which
        // the user feels as constant disconnect/reconnect. With a wide tolerance
        // the core only abandons the current node once it degrades badly (e.g.
        // the picked node drifts from ~180ms up toward ~480ms), not on every
        // minor jitter. A longer interval and no connection interruption keep
        // downloads and long-lived sockets alive across a switch.
        <String, dynamic>{
          'type': 'urltest',
          'tag': 'proxy',
          'outbounds': tags,
          'url': 'https://www.gstatic.com/generate_204',
          // Re-test only every 10 min so Auto isn't constantly re-shuffling.
          'interval': '10m0s',
          // 800ms band: since every node exits through the same Cloudflare
          // worker their latencies are close, so a small tolerance would let the
          // pick hop on trivial jitter — which the user feels as the connection
          // dropping. This wide band means Auto keeps the node it chose and only
          // abandons it once that node is genuinely failing (climbs ~800ms above
          // the alternatives), not on noise.
          'tolerance': 800,
          'idle_timeout': '30m0s',
          // Never tear down live connections when the pick changes: an in-flight
          // download or stream stays on its node instead of being cut.
          'interrupt_exist_connections': false,
        },
        ...nodeOutbounds,
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        <String, dynamic>{'type': 'dns', 'tag': 'dns-out'},
      ],
      // If any exit in the pool is UDP-native (Hysteria2/TUIC), let QUIC flow;
      // otherwise (an all-worker pool) keep blocking it so apps fall back to TCP.
      'route': _route(options,
          blockQuic: !picked.any((ProxyNode n) => n.protocol.isUdpNative)),
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

  static Map<String, dynamic> _tunInbound(SingboxRouteOptions o) =>
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'nova-tun',
        'inet4_address': '172.19.0.1/30',
        // iOS (lean) uses the gvisor stack: the system stack forwards raw IP
        // packets, so on the iOS extension large download packets fragment and
        // get dropped (bulk transfers crawl to ~0 while small requests still
        // work). gvisor terminates TCP in userspace (no fragmentation) and is
        // the standard for the iOS Network Extension. We keep it rather than
        // sing-box's `mixed` stack, which reintroduces that fragmentation risk.
        //
        // MTU: 4064 on iOS (matching Karing, which runs the same core in the
        // same ~50MB NE) instead of 1500. With gvisor a larger TUN MTU means
        // fewer packets/syscalls per byte, so bulk throughput improves without
        // the fragmentation drops the system stack would hit. Desktop/Android
        // keep the faster system stack + jumbo MTU.
        'mtu': o.lean ? 4064 : 9000,
        'auto_route': true,
        'strict_route': true,
        'stack': o.lean ? 'gvisor' : 'system',
        'sniff': true,
        'sniff_override_destination': false,
        // NOTE: platform.http_proxy (advertising a system HTTP proxy via
        // NEProxySettings) was tried in build 29 and is disabled again — it is a
        // prime suspect for build 29's broken browsing (all HTTP/HTTPS was routed
        // to the proxy port; if that listener misbehaves, browsers fail while
        // Telegram, which ignores the system proxy, keeps working). The native
        // openTun handler stays (dormant: isHTTPProxyEnabled() is now false) so
        // re-enabling is a one-line config change once the base path is verified.
      };

  static Map<String, dynamic> _dns(
    SingboxRouteOptions o, {
    Iterable<String> directDomains = const <String>[],
  }) {
    // The resolver for proxied (remote) DNS, over DoH so Iran's DNS tampering
    // can't touch it, reached THROUGH the proxy. IP-based, so it needs no
    // bootstrap resolver.
    //
    // Default is Google (8.8.8.8), NOT Cloudflare (1.1.1.1): the Nova exit is a
    // Cloudflare Worker, and a Worker cannot relay to Cloudflare's own endpoints
    // (loop protection), so a DoH query to 1.1.1.1 through the worker silently
    // fails. With no DNS, only apps that dial hardcoded IPs (Telegram) work
    // while browsers/Instagram can't resolve anything — the exact "only Telegram
    // opens" report. 8.8.8.8 is off-Cloudflare, so the worker can reach it.
    final String remote = o.dns.isEmpty ? '8.8.8.8' : o.dns;
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
        // These reference rule-sets that _route() defines (remote on the full
        // path, bundled-local on the lean/iOS path), so both can resolve Iran
        // domains for real and drop ads.
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
      case NodeProtocol.vmess:
        o['uuid'] = n.uuid;
        o['alter_id'] = n.vmessAlterId;
        o['security'] = n.vmessSecurity ?? 'auto';
      case NodeProtocol.hysteria2:
        if (n.password != null) o['password'] = n.password;
        if (n.obfsType != null && n.obfsType!.isNotEmpty) {
          o['obfs'] = <String, dynamic>{
            'type': n.obfsType,
            'password': n.obfsPassword ?? '',
          };
        }
      case NodeProtocol.tuic:
        o['uuid'] = n.uuid;
        o['password'] = n.password ?? '';
        o['congestion_control'] = n.congestionControl ?? 'bbr';
        o['udp_relay_mode'] = n.udpRelayMode ?? 'native';
    }
    if (n.tls) o['tls'] = _tls(n);
    // QUIC-native protocols (Hysteria2/TUIC) carry no ws/grpc transport.
    if (!n.protocol.isUdpNative) {
      final Map<String, dynamic>? transport = _transport(n);
      if (transport != null) o['transport'] = transport;
    }
    return o;
  }

  static Map<String, dynamic> _tls(ProxyNode n) {
    // Always forge a real browser's TLS ClientHello via uTLS, defaulting to
    // Chrome when the link didn't pin a fingerprint. Without this, a plain
    // worker VLESS node hands out Go's stock TLS fingerprint, which Iran's DPI
    // can flag as "not a browser"; a Chrome uTLS handshake blends in with normal
    // HTTPS. This is the client-side half of what Xray-based clients lean on;
    // the other half, ClientHello fragmentation, is applied just below (both the
    // iOS 1.12.x and Android 1.13.x cores now support it).
    // Reality already mandates uTLS, so this just makes every other TLS node
    // match that behaviour.
    final String fingerprint =
        (n.fingerprint != null && n.fingerprint!.isNotEmpty)
            ? n.fingerprint!
            : 'chrome';
    return <String, dynamic>{
      'enabled': true,
      'server_name': n.sni ?? n.server,
      if (n.allowInsecure) 'insecure': true,
      if (n.alpn.isNotEmpty) 'alpn': n.alpn,
      // TLS ClientHello fragmentation (sing-box 1.12+ outbound TLS option, keys
      // `fragment`/`fragment_fallback_delay` — the `tls_fragment` spelling is the
      // route-rule form, not this one). Splits the handshake so Iran's DPI can't
      // match the SNI in a single plaintext packet — the other half of the
      // anti-DPI story alongside the uTLS fingerprint, and the trick Xray-based
      // clients rely on. Not applied to Reality: its handshake already looks like
      // a real TLS session, so fragmenting it would only add latency.
      if (!n.isReality) ...<String, dynamic>{
        'fragment': true,
        'fragment_fallback_delay': '500ms',
      },
      if (n.isReality)
        'reality': <String, dynamic>{
          'enabled': true,
          'public_key': n.realityPublicKey,
          if (n.realityShortId != null && n.realityShortId!.isNotEmpty)
            'short_id': n.realityShortId,
        },
      'utls': <String, dynamic>{'enabled': true, 'fingerprint': fingerprint},
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

  static Map<String, dynamic> _route(SingboxRouteOptions o, {bool blockQuic = true}) {
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[
      <String, dynamic>{'protocol': 'dns', 'outbound': 'dns-out'},
      // Nova's own Cloudflare management calls (panel deploy, KV, etc.) must go
      // direct: routing them through the proxy fails because Cloudflare loop-
      // protects requests coming back through a CF-worker exit ("Failed host
      // lookup: api.cloudflare.com" during deploy).
      <String, dynamic>{'domain': _directHosts, 'outbound': 'direct'},
      // vless-over-WS/TLS (the Cloudflare Worker exit) carries TCP only, so QUIC
      // (HTTP/3 over UDP) can't be relayed and just times out — Instagram/
      // YouTube break while TCP apps like Telegram work. Block QUIC so those
      // apps fall back to TCP. But a real Hysteria2/TUIC exit carries UDP end to
      // end, so QUIC must pass through there (that's the whole speed win) — the
      // caller sets [blockQuic] false when any exit is UDP-native.
      if (blockQuic) <String, dynamic>{'protocol': 'quic', 'outbound': 'block'},
    ];
    final List<Map<String, dynamic>> ruleSets = <Map<String, dynamic>>[];

    // Lean (iOS) path: use BUNDLED (local) geosite rule-sets instead of the
    // remote ones the full path downloads — no startup fetch, and small enough
    // for the extension's memory budget. Domain-based only (geoip is skipped:
    // it can't match the fake IPs the lean DNS issues). Iran domains go direct
    // (faster, and off the worker), ads are blocked, everything else proxied.
    if (o.lean) {
      final List<Map<String, dynamic>> leanRuleSets = <Map<String, dynamic>>[];
      if (o.bypassLan && o.mode != SingboxMode.direct) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds && o.mode != SingboxMode.direct) {
        rules.add(<String, dynamic>{'rule_set': 'geosite-ads', 'outbound': 'block'});
        leanRuleSets.add(_localRuleSet('geosite-ads', kGeositeAdsFile));
      }
      if (o.bypassIran && o.mode == SingboxMode.rule) {
        rules.add(<String, dynamic>{'rule_set': 'geosite-ir', 'outbound': 'direct'});
        leanRuleSets.add(_localRuleSet('geosite-ir', kGeositeIrFile));
      }
      return <String, dynamic>{
        'rules': rules,
        if (leanRuleSets.isNotEmpty) 'rule_set': leanRuleSets,
        'final': o.mode == SingboxMode.direct ? 'direct' : 'proxy',
        'auto_detect_interface': true,
      };
    }

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

  /// The hosts the remote rule-sets are fetched from. They resolve via the
  /// direct DNS (see [_dns]) so the download never waits on the proxy.
  static const List<String> _ruleSetHosts = <String>['raw.githubusercontent.com'];

  /// Nova's own Cloudflare management endpoints. Resolved via direct DNS and
  /// routed direct (see [_route]) so panel deploy / KV calls work while the
  /// tunnel is up instead of failing a host lookup.
  static const List<String> _directHosts = <String>[
    'api.cloudflare.com',
    'dash.cloudflare.com',
  ];

  /// Placeholder in local rule-set paths, swapped for the real App Group
  /// container path by the iOS host (NovaProxyHost) before the config is written,
  /// so the extension reads the bundled `.srs` files from a valid absolute path.
  static const String ruleSetBaseToken = '__NOVA_BASE__';

  static const String kGeositeIrFile = 'geosite-ir.srs';
  static const String kGeositeAdsFile = 'geosite-ads.srs';

  /// Bundled asset path -> filename the host writes into the container. The iOS
  /// proxy controller ships exactly these on the lean path so the local
  /// rule-sets below resolve. Domain-based (geosite) only: geoip can't match the
  /// fake IPs the lean DNS hands out, so a geoip rule-set would never fire.
  static const Map<String, String> leanRuleSetAssets = <String, String>{
    'assets/rulesets/geosite-ir.srs': kGeositeIrFile,
    'assets/rulesets/geosite-ads.srs': kGeositeAdsFile,
  };

  static Map<String, dynamic> _localRuleSet(String tag, String fileName) =>
      <String, dynamic>{
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': '$ruleSetBaseToken/$fileName',
      };

  static Map<String, dynamic> _remoteRuleSet(String tag, String url) =>
      <String, dynamic>{
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': url,
        // Download directly, not through `proxy`. On the iOS/Android TUN path
        // the proxy isn't ready while the core is still starting, so a proxied
        // rule-set fetch deadlocks service start and the tunnel hangs on
        // "Connecting". Direct + direct-DNS resolution is self-contained.
        'download_detour': 'direct',
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
