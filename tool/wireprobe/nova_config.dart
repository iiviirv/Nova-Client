import 'dart:convert';
import 'dart:io';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

void main(List<String> args) {
  final int port = int.parse(args[0]);
  final ProxyNode n = parseShareLink(
    'vless://00000000-0000-4000-8000-000000000000@127.0.0.1:$port'
    '?security=tls&type=ws&sni=example.com&host=example.com&path=%2Fws#wire',
  )!;
  final Map<String, dynamic> cfg =
      SingboxConfig.buildMap(n, options: const SingboxRouteOptions(hardenTls: true));
  // Replace the tun/route bits with a plain socks inbound we can curl through.
  cfg['inbounds'] = <Map<String, dynamic>>[
    <String, dynamic>{
      'type': 'socks', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': 18080,
    }
  ];
  cfg.remove('route');
  cfg.remove('experimental');
  cfg['dns'] = <String, dynamic>{
    'servers': <Map<String, dynamic>>[
      <String, dynamic>{'tag': 'd', 'address': '1.1.1.1'}
    ],
  };
  cfg['log'] = <String, dynamic>{'level': 'error'};
  stdout.write(const JsonEncoder.withIndent(' ').convert(cfg));
}
