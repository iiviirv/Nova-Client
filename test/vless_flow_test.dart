import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// sing-box treats an unrecognised VLESS flow as fatal, not as something to
/// ignore, so a single server carrying an Xray-only flow used to stop the core
/// from starting and take every other server in the subscription down with it.
void main() {
  String cfgFor(String link) {
    final ProxyNode? n = parseShareLink(link);
    expect(n, isNotNull, reason: link);
    return jsonEncode(SingboxConfig.buildMap(n!));
  }

  String link(String flow) =>
      'vless://11111111-2222-3333-4444-555555555555@ex.example.com:443'
      '?security=tls&type=tcp&sni=ex.example.com'
      '${flow.isEmpty ? '' : '&flow=$flow'}#x';

  test('the flow sing-box supports is passed through', () {
    expect(cfgFor(link('xtls-rprx-vision')), contains('xtls-rprx-vision'));
  });

  test('an Xray-only variant is translated, not forwarded', () {
    // Seen in the wild: 2 of 1918 servers in the public free lists.
    final String out = cfgFor(link('xtls-rprx-vision-udp443'));
    expect(out, isNot(contains('xtls-rprx-vision-udp443')),
        reason: 'the core is fatal on this and the whole config dies');
    expect(out, contains('xtls-rprx-vision'),
        reason: 'the -udp443 suffix is client-side only, so the base flow is '
            'the faithful translation');
  });

  test('an unrecognised flow is dropped rather than guessed at', () {
    expect(cfgFor(link('some-future-flow')), isNot(contains('some-future-flow')));
    expect(cfgFor(link('some-future-flow')), isNot(contains('"flow"')));
  });

  test('no flow stays no flow', () {
    expect(cfgFor(link('')), isNot(contains('"flow"')));
  });
}
