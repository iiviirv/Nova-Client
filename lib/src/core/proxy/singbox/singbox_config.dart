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
  });

  final SingboxMode mode;
  final bool blockAds;
  final bool bypassIran;
  final bool bypassLan;
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
      'dns': _dns(options),
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

  static Map<String, dynamic> _dns(SingboxRouteOptions o) {
    return <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'remote',
          'address': 'https://1.1.1.1/dns-query',
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

  static Map<String, dynamic> _outbound(ProxyNode n) {
    final Map<String, dynamic> o = <String, dynamic>{
      'type': n.protocol.singboxType,
      'tag': 'proxy',
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
        'download_detour': 'direct',
      };
}
