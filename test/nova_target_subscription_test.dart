import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_outbound_import.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// The panel's `sub?...&target=nova` returns a sing-box config document, not a
/// share-link list. The subscription parser only understood links, so this
/// imported as an empty subscription ("it saves the URL but loads no configs")
/// until the user removed `&target=nova` by hand. The fixture is the real body
/// fetched from the live panel (secrets replaced), so this guards the true
/// shape.
void main() {
  final String body = File('test/fixtures_nova_target.json').readAsStringSync();

  test('a target=nova body is recognised as a sing-box document', () {
    expect(looksLikeSingboxConfig(body), isTrue);
    expect(looksLikeSingboxConfig('vless://x@h:1'), isFalse);
    expect(looksLikeSingboxConfig(base64.encode(utf8.encode('vless://x@h:1'))),
        isFalse);
  });

  test('parseSubscriptionBody yields the real servers, not zero', () {
    final List<ProxyNode> nodes = parseSubscriptionBody(body);
    // 6 vless + 1 trojan in the live panel; selector/urltest/direct are not
    // servers and must be skipped.
    expect(nodes.length, 7);
    expect(nodes.where((n) => n.protocol == NodeProtocol.vless), hasLength(6));
    expect(nodes.where((n) => n.protocol == NodeProtocol.trojan), hasLength(1));
    expect(nodes.every((n) => n.server.isNotEmpty && n.port > 0), isTrue);
  });

  test('tls, ws path and Host header survive the import', () {
    final ProxyNode n =
        parseSubscriptionBody(body).firstWhere((n) => n.tag == 'Azad');
    expect(n.tls, isTrue);
    expect(n.sni, 'vpn.novaproxy.qzz.io');
    expect(n.fingerprint, 'chrome');
    expect(n.network, 'ws');
    expect(n.wsPath, '/novapanel2026');
    expect(n.wsHost, 'vpn.novaproxy.qzz.io');
  });

  test('the panel-given names come through as tags', () {
    final Set<String> tags = parseSubscriptionBody(body).map((n) => n.tag).toSet();
    expect(tags, contains('Azad'));
    expect(tags, contains('Azad trojan'));
  });

  test('imported nodes round-trip into a config the builder accepts', () {
    final List<ProxyNode> nodes = parseSubscriptionBody(body);
    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(nodes);
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    // every imported server is present as an outbound
    final Set<String> servers = <String>{
      for (final o in outs) if (o is Map && o['server'] is String) o['server'] as String,
    };
    expect(servers, contains('vpn.novaproxy.qzz.io'));
    // and a real ws transport with the same path came back out
    final Map<String, dynamic> azad = (outs.firstWhere(
            (o) => o is Map && o['tag'] == 'node-0') as Map)
        .cast<String, dynamic>();
    expect((azad['transport'] as Map)['type'], 'ws');
  });

  test('a plain share-link subscription is untouched by the new path', () {
    const String links = 'vless://11111111-1111-1111-1111-111111111111@a.example.net:443'
        '?type=ws&security=tls#A\n';
    final List<ProxyNode> nodes = parseSubscriptionBody(links);
    expect(nodes, hasLength(1));
    expect(nodes.first.server, 'a.example.net');
  });
}
