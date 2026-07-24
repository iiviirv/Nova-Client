import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// Regression test for the "Unsupported or invalid profile link" bug: a
/// subscription profile (empty uri, URL in subscriptionUrl) must resolve to a
/// real connectable node instead of null.
void main() {
  test('subscription profile resolves to a connectable node', () async {
    final profile = ProxyProfile(
      id: 't',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl:
          'https://sub.lillio.org/sub?sub=user1&key=f2190e7f987c',
    );

    final node = await resolveProfileNode(profile);

    expect(node, isNotNull, reason: 'subscription should resolve to a node');
    expect(node!.uuid, isNotNull);
    expect(node.server, isNotEmpty);
    expect(node.tls, isTrue);
    // ignore: avoid_print
    print('resolved: ${node.server}:${node.port} uuid=${node.uuid} '
        'ws=${node.wsPath} host=${node.wsHost} sni=${node.sni}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('subscription expands to many nodes and builds a capped urltest',
      () async {
    final profile = ProxyProfile(
      id: 't',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl:
          'https://sub.lillio.org/sub?sub=user1&key=f2190e7f987c',
    );

    final nodes = await resolveProfileNodes(profile);
    expect(nodes.length, greaterThan(1),
        reason: 'a subscription should expand to multiple nodes');

    final Map<String, dynamic> cfg = SingboxConfig.buildMultiMap(nodes);
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    final Map<String, dynamic> auto = outs.firstWhere(
      (dynamic o) => (o as Map)['tag'] == 'proxy',
    ) as Map<String, dynamic>;

    expect(auto['type'], 'urltest', reason: 'fastest-node auto-selector');
    final int members = (auto['outbounds'] as List<dynamic>).length;
    expect(members, greaterThan(1));
    expect(members, lessThanOrEqualTo(SingboxConfig.kMaxAutoNodes),
        reason: 'capped for the iOS NE memory budget');
    // The rest of the config still targets the `proxy` tag.
    expect((cfg['route'] as Map)['final'], 'proxy');
    // ignore: avoid_print
    print('multi: ${nodes.length} nodes -> urltest of $members, '
        'json ${jsonEncode(cfg).length} bytes');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // The add dialog used to tag profiles purely by the selected pill, so a
  // mismatched kind produced "Unsupported or invalid profile link". Resolution
  // now keys off the actual content, so both mismatches still connect.
  group('content-driven resolution tolerates a wrong kind tag', () {
    const String shareLink =
        'vless://b90f8c50-b795-4a6d-84dd-d057e87c7f3a@104.17.214.82:443'
        '?security=tls&type=ws&path=/&host=sub.lillio.org&sni=sub.lillio.org#n';

    test('a share link mis-tagged as a subscription still parses', () async {
      final profile = ProxyProfile(
        id: 't',
        name: 'x',
        kind: ProxyKind.subscription, // wrong tag on purpose
        uri: '',
        subscriptionUrl: shareLink, // a vless:// link, not an http URL
      );
      final nodes = await resolveProfileNodes(profile);
      expect(nodes.length, 1);
      expect(nodes.first.server, '104.17.214.82');
      expect(nodes.first.uuid, isNotNull);
    });

    test('an http subscription mis-tagged as vless is still fetched', () async {
      final profile = ProxyProfile(
        id: 't',
        name: 'x',
        kind: ProxyKind.vless, // wrong tag on purpose
        uri: 'https://example.com/sub', // an http URL, not a share link
      );
      final nodes = await resolveProfileNodes(
        profile,
        fetch: (Uri url) async => base64.encode(utf8.encode(shareLink)),
      );
      expect(nodes.length, 1);
      expect(nodes.first.server, '104.17.214.82');
    });
  });

  // A mixed subscription (VLESS + Trojan + Shadowsocks) used to collapse to
  // just the uuid-carrying VLESS nodes, so a 500-node sub showed as ~41. Every
  // real protocol node must now survive; only a credential-less banner drops.
  test('mixed-protocol subscription keeps all real nodes', () async {
    const String vless =
        'vless://b90f8c50-b795-4a6d-84dd-d057e87c7f3a@104.17.214.82:443'
        '?security=tls&type=ws&path=/&host=h.example&sni=h.example#vless';
    const String trojan =
        'trojan://somepass@104.18.0.9:443?security=tls&sni=h.example#trojan';
    const String ss =
        'ss://YWVzLTI1Ni1nY206c2VjcmV0@104.19.0.7:8388#ss';
    final String body = base64.encode(utf8.encode('$vless\n$trojan\n$ss'));

    final profile = ProxyProfile(
      id: 't',
      name: 'mixed',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://example.com/sub',
    );
    final nodes = await resolveProfileNodes(
      profile,
      fetch: (Uri url) async => body,
    );

    final servers = nodes.map((n) => n.server).toSet();
    expect(servers, containsAll(<String>['104.17.214.82', '104.18.0.9', '104.19.0.7']),
        reason: 'VLESS, Trojan and Shadowsocks nodes must all survive');
  });

  // A no-domain node's subscription is served off a bare IP with a self-signed
  // cert. The relay (which validates TLS) can't read it, so fetchCoreConfig must
  // fall back to a direct fetch for a bare-IP host. Here we only assert that a
  // supplied fetcher (the relay, or this mock) still wins when it succeeds, so a
  // working relay/mock is never needlessly bypassed and the test never touches
  // the network. The self-signed fallback itself is exercised live (it needs a
  // real self-signed endpoint), verified end-to-end on the emulator.
  test('bare-IP subscription still uses a working fetcher (relay/mock) when it succeeds',
      () async {
    const String node =
        'vless://b90f8c50-b795-4a6d-84dd-d057e87c7f3a@45.32.100.50:443'
        '?security=tls&type=ws&path=/nova&host=45.32.100.50&sni=45.32.100.50'
        '&allowInsecure=1#me';
    final ProxyProfile profile = ProxyProfile(
      id: 't',
      name: 'no-domain',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: 'https://45.32.100.50/sub?token=abc',
    );
    Uri? seen;
    final nodes = await resolveProfileNodes(
      profile,
      fetch: (Uri url) async {
        seen = url;
        return base64.encode(utf8.encode(node));
      },
    );
    expect(seen?.host, '45.32.100.50',
        reason: 'a succeeding fetcher must be used, not bypassed');
    expect(nodes, hasLength(1));
    expect(nodes.first.server, '45.32.100.50');
  });
}
