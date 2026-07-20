import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

Map<String, dynamic> _proxyOut(ProxyNode n) =>
    (SingboxConfig.buildMap(n)['outbounds'] as List<dynamic>)
        .firstWhere((dynamic o) => o['tag'] == 'proxy') as Map<String, dynamic>;

void main() {
  test('socks:// with plain user:pass', () {
    final ProxyNode? n = parseShareLink('socks://user:pass@1.2.3.4:1080#S');
    expect(n, isNotNull);
    expect(n!.protocol, NodeProtocol.socks);
    expect(n.server, '1.2.3.4');
    expect(n.port, 1080);
    final Map<String, dynamic> o = _proxyOut(n);
    expect(o['type'], 'socks');
    expect(o['version'], '5');
    expect(o['username'], 'user');
    expect(o['password'], 'pass');
  });

  test('socks5:// with base64 userinfo and no port defaults to 1080', () {
    final String ui = base64.encode(utf8.encode('bob:secret'));
    final ProxyNode? n = parseShareLink('socks5://$ui@10.0.0.1#X');
    expect(n!.protocol, NodeProtocol.socks);
    expect(n.port, 1080);
    final Map<String, dynamic> o = _proxyOut(n);
    expect(o['username'], 'bob');
    expect(o['password'], 'secret');
  });

  test('http:// proxy with auth => http outbound', () {
    final ProxyNode? n = parseShareLink('http://u:p@proxy.example:8080#H');
    expect(n!.protocol, NodeProtocol.http);
    final Map<String, dynamic> o = _proxyOut(n);
    expect(o['type'], 'http');
    expect(o['username'], 'u');
    expect(o['password'], 'p');
    expect(o.containsKey('tls'), isFalse);
  });

  test('https:// proxy turns on TLS', () {
    final ProxyNode? n = parseShareLink('https://u:p@proxy.example:443#H');
    expect(n!.protocol, NodeProtocol.http);
    final Map<String, dynamic> o = _proxyOut(n);
    expect(o['type'], 'http');
    expect(o.containsKey('tls'), isTrue);
  });

  test('a bare http subscription URL is NOT parsed as a proxy', () {
    // No userinfo => not a proxy; parseShareLink returns null so it stays a sub.
    expect(parseShareLink('https://panel.example.com/sub?token=abc'), isNull);
  });
}
