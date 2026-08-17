import 'dart:convert';

import '../singbox/proxy_node.dart';

/// Phase-1 spike: translate a single Nova node into an Xray config, for the
/// Xray-only transports sing-box cannot run (xhttp / SplitHTTP today).
///
/// This is deliberately minimal: one outbound, a local `socks` inbound that a
/// Phase-2 tun2socks bridge will feed from the VpnService TUN. It exists to
/// prove the sing-box -> Xray config translation is tractable, not to replace
/// [SingboxConfig]. Only VLESS-over-xhttp is handled so far, which is the case
/// that has no sing-box path at all.
class XrayConfig {
  /// The local SOCKS port Xray listens on; the tun bridge dials this.
  static const int defaultSocksPort = 10808;

  /// Debug only: replace the xhttp outbound with a `freedom` (direct) exit, to
  /// prove the two-core data path (TUN -> sing-box -> SOCKS -> Xray -> internet)
  /// and socket protection on a device without a live xhttp server. Never true
  /// in a shipped build.
  static bool debugFreedomOutbound = false;

  static String build(ProxyNode node, {int socksPort = defaultSocksPort}) =>
      const JsonEncoder.withIndent('  ').convert(
          buildMap(node, socksPort: socksPort));

  static Map<String, dynamic> buildMap(ProxyNode node,
      {int socksPort = defaultSocksPort}) {
    if (node.network != 'xhttp') {
      throw const FormatException(
          'XrayConfig is the spike path for xhttp only; every other transport '
          'runs on sing-box.');
    }
    if (node.protocol != NodeProtocol.vless) {
      throw const FormatException('The xhttp spike only translates VLESS.');
    }
    final String sni = (node.sni?.isNotEmpty ?? false)
        ? node.sni!
        : (node.wsHost ?? node.server);
    final String host = (node.wsHost?.isNotEmpty ?? false)
        ? node.wsHost!
        : sni;

    final Map<String, dynamic> stream = <String, dynamic>{
      'network': 'xhttp',
      'security': node.tls ? 'tls' : 'none',
      if (node.tls)
        'tlsSettings': <String, dynamic>{
          'serverName': sni,
          if ((node.fingerprint ?? '').isNotEmpty &&
              node.fingerprint != 'unsafe')
            'fingerprint': node.fingerprint,
          'allowInsecure': node.allowInsecure,
        },
      'xhttpSettings': <String, dynamic>{
        'host': host,
        'path': node.wsPath ?? '/',
        'mode': 'auto',
      },
    };

    return <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': socksPort,
          'protocol': 'socks',
          'settings': <String, dynamic>{'udp': true},
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls'],
          },
        },
      ],
      'outbounds': <Map<String, dynamic>>[
        if (debugFreedomOutbound)
          <String, dynamic>{'tag': 'proxy', 'protocol': 'freedom'}
        else
        <String, dynamic>{
          'tag': 'proxy',
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
        },
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
    };
  }
}
