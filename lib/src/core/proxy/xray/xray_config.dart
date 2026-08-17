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
      'inbounds': <Map<String, dynamic>>[
        _socksInbound('socks-in', socksPort),
      ],
      'outbounds': <Map<String, dynamic>>[
        _outbound(node, tag: 'proxy'),
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
    };
  }

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
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[];
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
