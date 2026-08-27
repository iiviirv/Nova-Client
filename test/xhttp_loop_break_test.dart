import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Xray runs as a second core for xhttp, so in TUN mode its own dial to the
/// server is captured by sing-box's tunnel and fed back into the socks->Xray
/// chain forever. One rule sending the server out `direct` breaks that.
///
/// The rule going missing does not fail loudly: the tunnel comes up, says
/// "Connected", and carries nothing. That is what a Windows user reported, and
/// it is why this is pinned rather than trusted.
void main() {
  ProxyNode xhttp(String server) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: server,
        port: 2087,
        tag: 'x-$server',
        uuid: '11111111-2222-3333-4444-555555555555',
        tls: true,
        sni: 'example.com',
        network: 'xhttp',
        wsPath: '/somepath',
      );

  ProxyNode ws(String tag) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'ws.example.com',
        port: 443,
        tag: tag,
        uuid: '11111111-2222-3333-4444-555555555555',
        tls: true,
        network: 'ws',
        wsPath: '/w',
      );

  List<Map<String, dynamic>> rulesOf(Map<String, dynamic> cfg) =>
      ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

  test('a resolved xhttp server is matched by ip, ahead of everything', () {
    final Map<String, dynamic> cfg = SingboxConfig.buildXraySocksBridgeMap(
      10808,
      directServers: const <String>['203.0.113.7'],
    );
    final Map<String, dynamic> first = rulesOf(cfg).first;
    expect(first['ip_cidr'], <String>['203.0.113.7/32']);
    expect(first['outbound'], 'direct');
  });

  test('an xhttp server that did not resolve is still matched, by name', () {
    // The bug: this used to be passed only when it was an IP, so a name that
    // failed to resolve got no rule at all and the tunnel carried nothing.
    final Map<String, dynamic> cfg = SingboxConfig.buildXraySocksBridgeMap(
      10808,
      directServers: const <String>['vpn.example.com'],
    );
    final Map<String, dynamic> first = rulesOf(cfg).first;
    expect(first['domain'], <String>['vpn.example.com']);
    expect(first['outbound'], 'direct');
  });

  test('a subscription pool with xhttp nodes gets the same rule', () {
    // This path had no loop-break at all: buildMultiMap was called without
    // includeXhttp, so xhttp servers were dropped from the pool on desktop
    // while mobile ran them.
    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(
      <ProxyNode>[ws('a'), xhttp('203.0.113.8'), ws('b')],
      includeXhttp: true,
      xhttpDirectServers: const <String>['203.0.113.8'],
    );
    final Map<String, dynamic> first = rulesOf(cfg).first;
    expect(first['ip_cidr'], <String>['203.0.113.8/32']);
    expect(first['outbound'], 'direct');
    // And the xhttp node is actually in the pool, not silently dropped.
    expect(jsonEncode(cfg), contains('10808'));
  });

  test('a pool with no xhttp nodes gains no direct rule', () {
    final Map<String, dynamic> cfg =
        SingboxConfig.buildMultiMap(<ProxyNode>[ws('a'), ws('b')]);
    for (final Map<String, dynamic> r in rulesOf(cfg)) {
      expect(r['outbound'] == 'direct' && r['ip_cidr'] != null, isFalse);
    }
  });
}
