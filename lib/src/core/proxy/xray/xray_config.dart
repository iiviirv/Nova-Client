import 'dart:convert';

import '../singbox/proxy_node.dart';

/// Translate Nova xhttp nodes into an Xray config, for the Xray-only transports
/// sing-box cannot run (xhttp / SplitHTTP today).
///
/// Two shapes:
///  - [buildMap] / [build]: a single xhttp node behind one local `socks`
///    inbound. Used for a pinned/single xhttp profile; sing-box owns the TUN and
///    bridges it to this one socks port.
///  - [buildMultiMap] / [buildMulti]: N xhttp nodes, each behind its own local
///    `socks` inbound on a distinct port and routed to its own outbound. This is
///    what lets xhttp nodes join the auto-select pool: sing-box lists each of
///    those socks ports as an ordinary outbound in its urltest group, so the
///    xhttp nodes get measured, picked, and shown with a live ping through the
///    exact same command surface as every sing-box node. No separate Xray stats
///    channel is needed.
///
/// Only VLESS-over-xhttp is handled; every other transport runs on sing-box.
class XrayConfig {
  /// The local SOCKS port Xray listens on for the single-node path; the tun
  /// bridge dials this. The multi-node path assigns ports from here upward.
  static const int defaultSocksPort = 10808;

  /// Debug only: replace the xhttp outbound with a `freedom` (direct) exit, to
  /// prove the two-core data path (TUN -> sing-box -> SOCKS -> Xray -> internet)
  /// and socket protection on a device without a live xhttp server. Never true
  /// in a shipped build.
  static bool debugFreedomOutbound = false;

  static String build(ProxyNode node, {int socksPort = defaultSocksPort}) =>
      const JsonEncoder.withIndent('  ')
          .convert(buildMap(node, socksPort: socksPort));

  static Map<String, dynamic> buildMap(ProxyNode node,
      {int socksPort = defaultSocksPort}) {
    _assertXhttpVless(node);
    return <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': _dns(),
      'inbounds': <Map<String, dynamic>>[
        _socksInbound('socks-in', socksPort),
      ],
      'outbounds': <Map<String, dynamic>>[
        _outbound(node, tag: 'proxy'),
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'rules': <Map<String, dynamic>>[_dnsDirectRule()],
      },
    };
  }

  /// Xray DNS. Without it Xray has no resolver and every hostname a client asks
  /// for ("dns: exchange failed for www.google.com ...") fails and no traffic
  /// flows. UseIP + these public resolvers.
  static Map<String, dynamic> _dns() => <String, dynamic>{
        'servers': <String>['1.1.1.1', '8.8.8.8'],
        'queryStrategy': 'UseIP',
      };

  /// Route Xray's own DNS queries out the `direct` (freedom) outbound, not the
  /// proxy. Otherwise there is a chicken-and-egg: the proxy's first use is a DNS
  /// lookup, that lookup rides the proxy, and it fails before the xhttp session
  /// is up ("dns: exchange failed for ..." floods the log and nothing connects).
  /// Sending DNS direct (on a protected socket) resolves names independently, and
  /// the real connection to the resolved IP then establishes the xhttp session.
  static Map<String, dynamic> _dnsDirectRule() => <String, dynamic>{
        'type': 'field',
        'ip': <String>['1.1.1.1', '8.8.8.8'],
        'port': 53,
        'outboundTag': 'direct',
      };

  /// Build a config that serves [nodes] (all xhttp/VLESS), each on its own local
  /// socks inbound. Inbound i listens on `basePort + i` and is routed to that
  /// node's own outbound. The socks-port order matches the input order, so the
  /// caller can hand sing-box a socks outbound per node at `basePort + i` and
  /// keep the two cores' node lists aligned.
  static String buildMulti(List<ProxyNode> nodes,
          {int basePort = defaultSocksPort}) =>
      const JsonEncoder.withIndent('  ')
          .convert(buildMultiMap(nodes, basePort: basePort));

  static Map<String, dynamic> buildMultiMap(List<ProxyNode> nodes,
      {int basePort = defaultSocksPort}) {
    if (nodes.isEmpty) {
      throw const FormatException('buildMulti needs at least one xhttp node.');
    }
    final List<Map<String, dynamic>> inbounds = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> outbounds = <Map<String, dynamic>>[];
    // DNS goes direct (see _dnsDirectRule); it must come before the per-node
    // rules so a DNS query is never captured by a socks-in -> out rule.
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[
      _dnsDirectRule(),
    ];
    for (int i = 0; i < nodes.length; i++) {
      _assertXhttpVless(nodes[i]);
      final String inTag = 'socks-in-$i';
      final String outTag = 'out-$i';
      inbounds.add(_socksInbound(inTag, basePort + i));
      outbounds.add(_outbound(nodes[i], tag: outTag));
      rules.add(<String, dynamic>{
        'type': 'field',
        'inboundTag': <String>[inTag],
        'outboundTag': outTag,
      });
    }
    outbounds
      ..add(<String, dynamic>{'tag': 'direct', 'protocol': 'freedom'})
      ..add(<String, dynamic>{'tag': 'block', 'protocol': 'blackhole'});
    return <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': _dns(),
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': <String, dynamic>{'rules': rules},
    };
  }

  /// The local socks port the i-th multi-node xhttp exit listens on.
  static int socksPortForIndex(int index, {int basePort = defaultSocksPort}) =>
      basePort + index;

  static void _assertXhttpVless(ProxyNode node) {
    if (node.network != 'xhttp') {
      throw const FormatException(
          'XrayConfig is the path for xhttp only; every other transport runs '
          'on sing-box.');
    }
    if (node.protocol != NodeProtocol.vless) {
      throw const FormatException('The xhttp path only translates VLESS.');
    }
  }

  static Map<String, dynamic> _socksInbound(String tag, int port) =>
      <String, dynamic>{
        'tag': tag,
        'listen': '127.0.0.1',
        'port': port,
        'protocol': 'socks',
        'settings': <String, dynamic>{'udp': true},
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls'],
        },
      };

  static Map<String, dynamic> _outbound(ProxyNode node, {required String tag}) {
    if (debugFreedomOutbound) {
      return <String, dynamic>{'tag': tag, 'protocol': 'freedom'};
    }
    final String sni = (node.sni?.isNotEmpty ?? false)
        ? node.sni!
        : (node.wsHost ?? node.server);
    final String host = (node.wsHost?.isNotEmpty ?? false) ? node.wsHost! : sni;
    // uTLS fingerprint: Reality needs a real one (default chrome); plain TLS
    // keeps whatever the node carries, and only sets it when present.
    final String fp = (node.fingerprint ?? '').isNotEmpty &&
            node.fingerprint != 'unsafe'
        ? node.fingerprint!
        : 'chrome';
    // Security block: Reality (borrowed cert, direct-IP, survives a CDN-less
    // path) vs plain TLS. xhttp behind Cloudflare needs plain TLS, but a
    // standalone Reality inbound is the way to run xhttp on a direct IP.
    final Map<String, dynamic> security = node.isReality
        ? <String, dynamic>{
            'security': 'reality',
            'realitySettings': <String, dynamic>{
              'serverName': sni,
              'fingerprint': fp,
              'publicKey': node.realityPublicKey,
              if ((node.realityShortId ?? '').isNotEmpty)
                'shortId': node.realityShortId,
              // spiderX default "/" matches the server's spider path when unset.
              'spiderX': '/',
            },
          }
        : <String, dynamic>{
            'security': node.tls ? 'tls' : 'none',
            if (node.tls)
              'tlsSettings': <String, dynamic>{
                'serverName': sni,
                if ((node.fingerprint ?? '').isNotEmpty &&
                    node.fingerprint != 'unsafe')
                  'fingerprint': node.fingerprint,
                // NB: no `allowInsecure`. Xray 26.3.27 REMOVED it (setting it
                // true makes the whole config fail to build: "the feature
                // allowInsecure has been removed ... migrated to
                // pinnedPeerCertSha256"). Verifying a self-signed xhttp cert
                // needs that pin, which we don't carry yet, so a self-signed /
                // no-domain xhttp node stays unsupported rather than breaking the
                // config for every valid-cert node.
              },
          };
    final Map<String, dynamic> stream = <String, dynamic>{
      'network': 'xhttp',
      ...security,
      'xhttpSettings': <String, dynamic>{
        'host': host,
        'path': node.wsPath ?? '/',
        'mode': 'auto',
      },
    };
    return <String, dynamic>{
      'tag': tag,
      'protocol': 'vless',
      'settings': <String, dynamic>{
        'vnext': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': node.server,
            'port': node.port,
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': node.uuid ?? '',
                'encryption': 'none',
                if ((node.flow ?? '').isNotEmpty) 'flow': node.flow,
              },
            ],
          },
        ],
      },
      'streamSettings': stream,
    };
  }
}
