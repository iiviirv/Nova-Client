import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// An unknown uTLS fingerprint is fatal to the sing-box core, so one node
/// carrying an Xray-only value stops every other node in the same config from
/// being dialled. That is what made the ping test spin for ever: 88 of the 200
/// nodes in a measuring pool were Reality servers whose links carry fp=unsafe.
void main() {
  ProxyNode node(String extra) => parseShareLink(
        'vless://11111111-2222-3333-4444-555555555555@ex.example.com:443'
        '?security=reality&pbk=aGVsbG8td29ybGQtcmVhbGl0eS1wdWJrZXktMDAwMA'
        '&sid=ab&type=tcp&sni=ex.example.com$extra#x',
      )!;

  String tlsOf(ProxyNode n) => jsonEncode(SingboxConfig.buildMap(n));

  test('a Reality node with fp=unsafe does not reach the core', () {
    final String out = tlsOf(node('&fp=unsafe'));
    expect(out, isNot(contains('"fingerprint":"unsafe"')),
        reason: 'the core refuses the whole config on this');
    expect(out, contains('"fingerprint":"chrome"'));
  });

  test('a fingerprint the core knows is left alone', () {
    for (final String f in <String>['chrome', 'firefox', 'safari', 'ios']) {
      expect(tlsOf(node('&fp=$f')), contains('"fingerprint":"$f"'));
    }
  });

  test('an unknown fingerprint falls back rather than being forwarded', () {
    final String out = tlsOf(node('&fp=some-future-browser'));
    expect(out, isNot(contains('some-future-browser')));
    expect(out, contains('"fingerprint":"chrome"'));
  });

  test('the bypass still turns uTLS off for a plain TLS node', () {
    // Non-Reality hardened nodes honour fp=unsafe properly, by disabling uTLS
    // instead of naming a browser. That path must not change.
    final ProxyNode plain = parseShareLink(
      'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443'
      '?security=tls&type=ws&sni=ex.example.com&fp=unsafe&path=%2Fw#x',
    )!;
    final String out = jsonEncode(SingboxConfig.buildMap(plain));
    expect(out, contains('"utls":{"enabled":false}'));
    expect(out, isNot(contains('unsafe')));
  });
}
