import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// Nova Server writes exactly this shape (see `naiveLine` in the node agent's
/// subscription.mjs): five query parameters that v2rayN itself round-trips.
const String kNaiveLink =
    'naive+https://alice%40example.com:s3cr3t-pass@node.example.com:443'
    '?security=tls&insecure=0&allowInsecure=0&type=tcp&headerType=none'
    '#Alice%20(NaiveProxy)';

void main() {
  group('NaiveProxy links', () {
    test('a server-issued link parses into a node', () {
      final ProxyNode? n = parseShareLink(kNaiveLink);
      expect(n, isNotNull);
      expect(n!.protocol, NodeProtocol.naive);
      expect(n.server, 'node.example.com');
      expect(n.port, 443);
      // The username and password are percent-encoded in the link; an email
      // address as the username is the normal case for a Nova Server user.
      expect(n.uuid, 'alice@example.com');
      expect(n.password, 's3cr3t-pass');
      expect(n.tls, isTrue, reason: 'naive is always inside TLS');
      expect(n.sni, 'node.example.com',
          reason: 'naive has no separate SNI: the authority IS the TLS name');
      expect(n.allowInsecure, isFalse);
      expect(n.tag, contains('Alice'));
    });

    test('a self-signed node keeps its insecure flag', () {
      // Writing 0 here would hand every user on a self-signed node a link that
      // cannot complete a handshake, which is why the server emits the real
      // value rather than a constant.
      final ProxyNode? n = parseShareLink(
        'naive+https://u:p@10.0.0.1:443?security=tls&insecure=1#Self',
      );
      expect(n!.allowInsecure, isTrue);
    });

    test('allowInsecure is honoured as well as insecure', () {
      final ProxyNode? n = parseShareLink(
        'naive+https://u:p@10.0.0.1:443?allowInsecure=1#Self',
      );
      expect(n!.allowInsecure, isTrue);
    });

    test('a link with no credentials is rejected, not half-built', () {
      expect(parseShareLink('naive+https://node.example.com:443#x'), isNull);
      expect(parseShareLink('naive+https://onlyuser@node.example.com:443'),
          isNull);
    });

    test('naive+quic is left unsupported rather than downgraded', () {
      // sing-box cannot dial the QUIC form. Silently treating it as TLS would
      // produce a config that connects to nothing.
      expect(parseShareLink('naive+quic://u:p@node.example.com:443'), isNull);
    });

    test('the outbound is what sing-box expects', () {
      final ProxyNode n = parseShareLink(kNaiveLink)!;
      final Map<String, dynamic> cfg = SingboxConfig.buildMap(n);
      final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
      final Map<String, dynamic> o = outs.firstWhere(
        (dynamic e) => (e as Map<String, dynamic>)['type'] == 'naive',
      ) as Map<String, dynamic>;

      expect(o['server'], 'node.example.com');
      expect(o['server_port'], 443);
      expect(o['username'], 'alice@example.com');
      expect(o['password'], 's3cr3t-pass');
      expect((o['tls'] as Map<String, dynamic>)['enabled'], isTrue);
      // naive has no ws/grpc variant: emitting a transport block makes the
      // outbound invalid, and a `type=tcp` in the link is v2rayN filling in a
      // field the protocol does not have.
      expect(o.containsKey('transport'), isFalse);
    });

    test('a naive config is detected so a core without it can refuse', () {
      final ProxyNode n = parseShareLink(kNaiveLink)!;
      final String json = SingboxConfig.build(n);
      expect(CoreFeatures.usesNaive(json), isTrue);
      expect(CoreFeatures.usesAwg(json), isFalse);
    });

    test('an ordinary config is not mistaken for naive', () {
      final ProxyNode n = ProxyNode(
        protocol: NodeProtocol.vless,
        server: 'example.com',
        port: 443,
        tls: true,
        uuid: '12345678-90ab-cdef-1234-567890abcdef',
      );
      expect(CoreFeatures.usesNaive(SingboxConfig.build(n)), isFalse);
    });
  });

  group('what a subscription contained but Nova cannot run', () {
    String sub(List<String> lines) => base64.encode(utf8.encode(lines.join('\n')));

    test('unsupported schemes are counted by name, not silently dropped', () {
      // The failure this replaces: an operator creates a mieru inbound, it
      // appears in no client, and nothing anywhere says why.
      final List<ProxyNode> nodes = parseSubscriptionBody(sub(<String>[
        'vless://12345678-90ab-cdef-1234-567890abcdef@a.example.com:443?security=tls&type=ws#A',
        'mieru://whatever@b.example.com:443#B',
        'mieru://whatever@c.example.com:443#C',
        'naive+quic://u:p@d.example.com:443#D',
      ]));
      expect(nodes.length, 1);
      expect(lastSkippedLinks.total, 3);
      expect(lastSkippedLinks.byScheme['mieru'], 2);
      expect(lastSkippedLinks.byScheme['naive+quic'], 1);
      expect(lastSkippedLinks.schemes.first, 'mieru',
          reason: 'most common first, so the note names what matters');
    });

    test('a naive link now counts as supported, not skipped', () {
      final List<ProxyNode> nodes = parseSubscriptionBody(sub(<String>[
        kNaiveLink,
      ]));
      expect(nodes.length, 1);
      expect(nodes.single.protocol, NodeProtocol.naive);
      expect(lastSkippedLinks.isEmpty, isTrue);
    });

    test('a clean subscription reports nothing skipped', () {
      final List<ProxyNode> nodes = parseSubscriptionBody(sub(<String>[
        'vless://12345678-90ab-cdef-1234-567890abcdef@a.example.com:443?security=tls&type=ws#A',
        'trojan://pw@b.example.com:443?security=tls#B',
      ]));
      expect(nodes.length, 2);
      expect(lastSkippedLinks.isEmpty, isTrue);
      expect(lastSkippedLinks.total, 0);
    });

    test('a junk line is counted without becoming a label', () {
      // A long malformed line must not turn into the scheme shown to the user.
      parseSubscriptionBody(sub(<String>['${'x' * 200}://y']));
      expect(lastSkippedLinks.byScheme.keys.single, '?');
    });
  });
}
