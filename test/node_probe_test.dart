import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/node_probe.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

/// These pin the property the whole feature exists for: a node is only given a
/// latency when something was actually proven about it. The bug this replaced
/// was a bare TCP connect printed as a ping, which made every Cloudflare-fronted
/// node look healthy on a network where none of them worked.
void main() {
  group('what a probe is allowed to claim', () {
    test('an unreachable host is never given a latency', () async {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'nova-does-not-exist.invalid',
        port: 443,
        tls: true,
        network: 'ws',
        wsPath: '/x',
        sni: 'nova-does-not-exist.invalid',
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.unreachable);
      expect(r.latencyMs, isNull);
      expect(r.ok, isFalse);
    });

    test('Reality is reported as untestable, not measured', () async {
      // Reality forwards an unauthenticated handshake to the real site it
      // borrows its certificate from, so a successful TLS handshake says
      // nothing whatsoever about the node.
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: '127.0.0.1',
        port: 443,
        tls: true,
        sni: 'www.microsoft.com',
        realityPublicKey: 'abc',
        realityShortId: '01',
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.untestable);
      expect(r.latencyMs, isNull);
      expect(r.reason, isNotNull);
    });

    test('an obfuscated Hysteria2 endpoint is untestable, not blocked',
        () async {
      // Salamander obfuscation makes the server drop anything that is not
      // already obfuscated, so silence is not evidence of censorship.
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.hysteria2,
        server: '127.0.0.1',
        port: 443,
        password: 'x',
        obfsType: 'salamander',
        obfsPassword: 'y',
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.untestable);
    });

    test('a plain TCP node is untestable rather than "fast"', () async {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.shadowsocks,
        server: '127.0.0.1',
        port: 8388,
        tls: false,
        password: 'x',
        method: 'aes-128-gcm',
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.untestable);
      expect(r.latencyMs, isNull);
    });

    test('the http transport is untestable rather than guessed at', () async {
      // sing-box's `http` transport negotiates HTTP/1.1 or h2 depending on TLS
      // and wraps the stream differently in each case; a wrong guess would read
      // as censorship.
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: '127.0.0.1',
        port: 443,
        tls: true,
        network: 'http',
        uuid: '12345678-90ab-cdef-1234-567890abcdef',
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.untestable);
    });

    test('WireGuard is untestable without the peer keys', () async {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.awg,
        server: '127.0.0.1',
        port: 51820,
      );
      final NodeProbeResult r =
          await probeNode(node, timeout: const Duration(seconds: 2));
      expect(r.quality, NodeProbeQuality.untestable);
    });
  });

  group('ranking', () {
    test('a proved node outranks a merely reachable one, however fast', () {
      const NodeProbeResult proved =
          NodeProbeResult(NodeProbeQuality.proxied, latencyMs: 900);
      const NodeProbeResult answered =
          NodeProbeResult(NodeProbeQuality.handshake, latencyMs: 10);
      expect(proved.sortKey, lessThan(answered.sortKey));
    });

    test('anything measured outranks unknown, and unknown outranks dead', () {
      const NodeProbeResult answered =
          NodeProbeResult(NodeProbeQuality.handshake, latencyMs: 800);
      const NodeProbeResult unknown = NodeProbeResult.untestable('x');
      const NodeProbeResult dead = NodeProbeResult.unreachable();
      expect(answered.sortKey, lessThan(unknown.sortKey));
      expect(unknown.sortKey, lessThan(dead.sortKey));
    });

    test('only measured tiers carry a latency into the UI', () {
      expect(NodeProbeQuality.proxied.carriesLatency, isTrue);
      expect(NodeProbeQuality.handshake.carriesLatency, isTrue);
      expect(NodeProbeQuality.untestable.carriesLatency, isFalse);
      expect(NodeProbeQuality.unreachable.carriesLatency, isFalse);
    });
  });

  group('wire formats', () {
    test('the VLESS header addresses the probe destination', () {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: '1.2.3.4',
        port: 443,
        uuid: '12345678-90ab-cdef-1234-567890abcdef',
      );
      final List<int> h = debugRequestHeader(node)!;
      expect(h[0], 0, reason: 'VLESS version byte');
      expect(h.sublist(1, 17), <int>[
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
      ]);
      expect(h[17], 0, reason: 'no addons');
      expect(h[18], 1, reason: 'TCP connect');
      expect((h[19] << 8) | h[20], 80, reason: 'destination port');
      expect(h[21], 2, reason: 'domain address type');
      expect(
        utf8.decode(h.sublist(23, 23 + h[22])),
        'www.gstatic.com',
      );
    });

    test('a Vision-flow node is not probed with a plain header', () {
      // XTLS Vision changes the framing after the header, so a probe that
      // ignored it would misread a healthy node as broken.
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: '1.2.3.4',
        port: 443,
        uuid: '12345678-90ab-cdef-1234-567890abcdef',
        flow: 'xtls-rprx-vision',
      );
      expect(debugRequestHeader(node), isNull);
    });

    test('a malformed UUID yields no header instead of garbage', () {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: '1.2.3.4',
        port: 443,
        uuid: 'not-a-uuid',
      );
      expect(debugRequestHeader(node), isNull);
    });

    test('the Trojan header is the password hash, then the destination', () {
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.trojan,
        server: '1.2.3.4',
        port: 443,
        password: 'hunter2',
      );
      final List<int> h = debugRequestHeader(node)!;
      final String hash = sha224.convert(utf8.encode('hunter2')).toString();
      expect(utf8.decode(h.sublist(0, 56)), hash);
      expect(h.sublist(56, 58), <int>[0x0d, 0x0a]);
      expect(h[58], 1, reason: 'CONNECT');
      expect(h[59], 3, reason: 'domain address type');
      expect(utf8.decode(h.sublist(61, 61 + h[60])), 'www.gstatic.com');
      final int portAt = 61 + h[60];
      expect((h[portAt] << 8) | h[portAt + 1], 80);
      expect(h.sublist(portAt + 2), <int>[0x0d, 0x0a]);
    });

    test('encrypted-header protocols build no header at all', () {
      // Reimplementing VMess and Shadowsocks ciphers to measure a ping would be
      // a second crypto implementation to keep correct; those nodes stop at the
      // handshake tier instead.
      for (final NodeProtocol p in <NodeProtocol>[
        NodeProtocol.vmess,
        NodeProtocol.shadowsocks,
      ]) {
        final ProxyNode node = ProxyNode(
          protocol: p,
          server: '1.2.3.4',
          port: 443,
          uuid: '12345678-90ab-cdef-1234-567890abcdef',
          password: 'x',
        );
        expect(debugRequestHeader(node), isNull, reason: p.name);
      }
    });

    test('client WebSocket frames are masked, as the protocol requires', () {
      final List<int> payload = <int>[1, 2, 3, 4, 5];
      final List<int> frame = debugWsFrame(payload);
      expect(frame[0], 0x82, reason: 'FIN + binary');
      expect(frame[1] & 0x80, 0x80, reason: 'mask bit set');
      expect(frame[1] & 0x7f, payload.length);
      final List<int> mask = frame.sublist(2, 6);
      final List<int> body = frame.sublist(6);
      expect(body.length, payload.length);
      expect(<int>[
        for (int i = 0; i < body.length; i++) body[i] ^ mask[i & 3],
      ], payload);
    });

    test('a long WebSocket payload uses the 16-bit length form', () {
      final List<int> payload = List<int>.filled(300, 7);
      final List<int> frame = debugWsFrame(payload);
      expect(frame[1] & 0x7f, 126);
      expect((frame[2] << 8) | frame[3], 300);
    });

    test('the QUIC probe is padded past the size a server will answer', () {
      // A QUIC server discards an Initial packet under 1200 bytes without a
      // reply, so an unpadded probe would read every UDP node as blocked.
      final Uint8List p = debugQuicVersionProbe();
      expect(p.length, greaterThanOrEqualTo(1200));
      expect(p[0] & 0x80, 0x80, reason: 'long header');
      expect(p.sublist(1, 5), <int>[0x1a, 0x2a, 0x3a, 0x4a],
          reason: 'a version no server implements, which forces a reply');
    });
  });

  group('reading the destination reply', () {
    test('an HTTP status line counts, anything else does not', () {
      expect(debugIsHttpReply('HTTP/1.1 204 No Content'), isTrue);
      expect(debugIsHttpReply('HTTP/1.0 200 OK'), isTrue);
      expect(debugIsHttpReply('HTTP/1.1 301 Moved'), isTrue);
      expect(debugIsHttpReply('HTTP/1.1 502 Bad Gateway'), isFalse);
      expect(debugIsHttpReply('SSH-2.0-OpenSSH'), isFalse);
      expect(debugIsHttpReply(''), isFalse);
    });
  });

  group('live network', () {
    test('a real WebSocket endpoint answers the handshake tier', () async {
      // Cloudflare's own site is not a proxy node, but it does complete TLS with
      // SNI and answer an upgrade request, which is exactly the tier being
      // measured. Tagged: needs the network.
      final ProxyNode node = ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'cloudflare.com',
        port: 443,
        tls: true,
        network: 'ws',
        wsPath: '/',
        sni: 'cloudflare.com',
        uuid: '00000000-0000-0000-0000-000000000000',
      );
      final NodeProbeResult r = await probeNode(
        node,
        timeout: const Duration(seconds: 8),
      );
      // It must not claim the proxied tier: nothing was carried through it.
      expect(r.quality, isNot(NodeProbeQuality.proxied));
    }, tags: <String>['network']);
  });
}
