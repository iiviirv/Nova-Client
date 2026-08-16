import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

void main() {
  test('profile latency can be persisted and explicitly cleared', () {
    final ProxyProfile profile = ProxyProfile(
      id: 'p',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.com/sub',
      lastLatencyMs: 42,
    );

    expect(profile.copyWith().lastLatencyMs, 42);
    expect(profile.copyWith(lastLatencyMs: 75).lastLatencyMs, 75);
    expect(profile.copyWith(lastLatencyMs: null).lastLatencyMs, isNull);
  });

  test('a pinned node keeps its name across copyWith and json, and can clear',
      () {
    final ProxyProfile p = ProxyProfile(
      id: 'p',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.com/sub',
      pinnedNode: '104.17.1.1:443:vless:/p',
      pinnedName: 'Germany 1',
    );
    // Survives a round-trip so the pin (and its rotation-proof name) persists.
    final ProxyProfile back = ProxyProfile.fromJson(p.toJson());
    expect(back.pinnedNode, '104.17.1.1:443:vless:/p');
    expect(back.pinnedName, 'Germany 1');
    // copyWith keeps it untouched, and Auto (null) clears both.
    expect(p.copyWith(hardenTls: true).pinnedName, 'Germany 1');
    final ProxyProfile auto =
        p.copyWith(pinnedNode: null, pinnedName: null);
    expect(auto.pinnedNode, isNull);
    expect(auto.pinnedName, isNull);
  });

  test('node selection keys distinguish transports and accept legacy keys', () {
    final ProxyNode ws = ProxyNode(
      protocol: NodeProtocol.vless,
      server: '104.18.0.1',
      port: 443,
      network: 'ws',
      wsPath: '/ws',
    );
    final ProxyNode grpc = ProxyNode(
      protocol: NodeProtocol.vless,
      server: '104.18.0.1',
      port: 443,
      network: 'grpc',
    );

    expect(proxyNodeKey(ws), isNot(proxyNodeKey(grpc)));
    expect(proxyNodeMatchesKey(ws, proxyNodeKey(ws)), isTrue);
    expect(proxyNodeMatchesKey(ws, '104.18.0.1:443'), isTrue);
    expect(proxyNodeMatchesKey(ws, proxyNodeKey(grpc)), isFalse);
  });
}
