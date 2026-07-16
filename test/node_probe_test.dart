import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/node_probe.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

void main() {
  test('TLS probe completes a real handshake with the node SNI', () async {
    final ProxyNode node = ProxyNode(
      protocol: NodeProtocol.vless,
      server: 'cloudflare.com',
      port: 443,
      tls: true,
      sni: 'cloudflare.com',
      uuid: '00000000-0000-0000-0000-000000000000',
    );
    final int? ms = await probeNodeMs(node, timeout: const Duration(seconds: 8));
    expect(ms, isNotNull);
    expect(ms, greaterThanOrEqualTo(0));
  }, tags: <String>['network']);

  test('unreachable host reads as null, not a green ping', () async {
    final ProxyNode node = ProxyNode(
      protocol: NodeProtocol.vless,
      server: 'nova-does-not-exist.invalid',
      port: 443,
      tls: true,
      sni: 'nova-does-not-exist.invalid',
    );
    final int? ms =
        await probeNodeMs(node, timeout: const Duration(seconds: 2));
    expect(ms, isNull);
  });

  test('plaintext node keeps the plain TCP probe', () async {
    final ProxyNode node = ProxyNode(
      protocol: NodeProtocol.shadowsocks,
      server: 'cloudflare.com',
      port: 443,
      tls: false,
      password: 'x',
      method: 'aes-128-gcm',
    );
    final int? ms = await probeNodeMs(node, timeout: const Duration(seconds: 8));
    expect(ms, isNotNull);
  }, tags: <String>['network']);
}
