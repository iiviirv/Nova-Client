import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_fronting.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// A clean IPv6 address is only worth finding if it survives the rest of the
/// way: into the node, into the config, and into a core that accepts it. The
/// machine this was written on has no global IPv6, so the dial cannot be tested
/// here, but everything up to the dial can be, and is.
void main() {
  ProxyNode node(String server) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: server,
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        sni: 'example.com',
        network: 'ws',
        wsPath: '/ws',
        tag: 'n',
      );

  Map<String, dynamic> outbound(ProxyNode n) {
    final Map<String, dynamic> m = SingboxConfig.buildMap(n);
    return (m['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
  }

  test('a v6 address reaches the config unmangled', () {
    final Map<String, dynamic> o = outbound(node('2606:4700::6812:a76'));
    expect(o['server'], '2606:4700::6812:a76',
        reason: 'sing-box takes a bare v6 address here; brackets belong to '
            'URIs, and adding them makes the outbound invalid');
    expect(o['server_port'], 443);
  });

  test('the SNI is untouched by the address family', () {
    final Map<String, dynamic> o = outbound(node('2606:4700::6812:a76'));
    expect((o['tls'] as Map<String, dynamic>)['server_name'], 'example.com',
        reason: 'the whole point of a clean address is a name that is not it');
  });

  test('the core accepts the config built around a v6 address', () {
    const String core = 'assets/bin/sing-box-macos-arm64';
    if (!File(core).existsSync()) return;
    final Map<String, dynamic> m =
        SingboxConfig.buildMap(node('2606:4700::6812:a76'));
    final File f = File('${Directory.systemTemp.path}/nova_v6_check.json');
    f.writeAsStringSync(jsonEncode(m));
    final ProcessResult r =
        Process.runSync(core, <String>['check', '-c', f.path]);
    expect(r.exitCode, 0, reason: 'core rejected it: ${r.stderr}${r.stdout}');
  });

  test('a v6 address counts as an address, so fronting leaves it alone', () {
    // couldBeFronted exists to spot nodes that need an address filled in. A
    // node already carrying a v6 one is not such a node, and re-addressing it
    // onto v4 would undo the only thing that reaches some networks.
    expect(CleanIpFronting.couldBeFronted(node('2606:4700::6812:a76')), isFalse);
    expect(CleanIpFronting.couldBeFronted(node('example.com')), isTrue,
        reason: 'a name still wants an address');
  });
}
