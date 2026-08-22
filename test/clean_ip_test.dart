import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_fronting.dart';
import 'package:nova_client/src/core/cleanip/clean_ip_store.dart';
import 'package:nova_client/src/core/cleanip/cloudflare_ranges.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Dialling a Cloudflare-fronted server through an address this device found,
/// instead of through the name its provider published.
///
/// The point is not speed. A public subscription's domains are filtered within
/// days in Iran while the addresses behind them keep working, and Nova's
/// SNI-block bypass only applies to a node that is already addressed by IP, so
/// a domain-addressed config previously got no bypass at all and died with its
/// domain.
void main() {
  ProxyNode node(String link) => parseShareLink(link)!;

  const CleanIp clean = CleanIp(
      ip: '104.16.4.103', port: 443, latencyMs: 90, foundAtMs: 0);

  group('knowing what is Cloudflare', () {
    test('published ranges are recognised', () {
      expect(isCloudflareIp('104.16.4.103'), isTrue);
      expect(isCloudflareIp('172.64.0.1'), isTrue);
      expect(isCloudflareIp('188.114.98.0'), isTrue);
    });

    test('everything else is not', () {
      expect(isCloudflareIp('8.8.8.8'), isFalse);
      expect(isCloudflareIp('31.76.80.69'), isFalse);
      expect(isCloudflareIp('not-an-ip'), isFalse);
      // Just outside 104.16.0.0/13.
      expect(isCloudflareIp('104.32.0.1'), isFalse);
    });
  });

  group('which nodes are even candidates', () {
    test('a TLS node addressed by name on a Cloudflare port is', () {
      expect(
          CleanIpFronting.couldBeFronted(node(
              'vless://00000000-0000-0000-0000-000000000001@sub.example.com:443'
              '?type=ws&security=tls&sni=sub.example.com&path=%2Fws#a')),
          isTrue);
    });

    test('a node already addressed by IP is not', () {
      // It needs no fronting and it already gets the bypass.
      expect(
          CleanIpFronting.couldBeFronted(node(
              'vless://00000000-0000-0000-0000-000000000001@104.16.4.103:443'
              '?type=ws&security=tls&sni=sub.example.com&path=%2Fws#a')),
          isFalse);
    });

    test('a node without TLS is not', () {
      expect(
          CleanIpFronting.couldBeFronted(node(
              'vless://00000000-0000-0000-0000-000000000001@sub.example.com:80'
              '?type=ws&path=%2Fws#a')),
          isFalse);
    });

    test('a node on a port Cloudflare does not terminate TLS on is not', () {
      expect(
          CleanIpFronting.couldBeFronted(node(
              'vless://00000000-0000-0000-0000-000000000001@sub.example.com:8080'
              '?type=ws&security=tls&sni=sub.example.com&path=%2Fws#a')),
          isFalse);
    });
  });

  test('a name that does not resolve onto Cloudflare is left alone', () async {
    // The lookup fails or points elsewhere, and guessing would break a working
    // config, so the node comes back byte for byte as it went in.
    final List<ProxyNode> input = <ProxyNode>[
      node('vless://00000000-0000-0000-0000-000000000001'
          '@nothing.invalid:443?type=ws&security=tls&path=%2Fws#a'),
    ];
    final List<ProxyNode> out = await CleanIpFronting.apply(input, clean,
        lookupTimeout: const Duration(milliseconds: 300));
    expect(out.single.server, 'nothing.invalid');
    expect(out.single.port, 443);
  });

  test('fronting is what turns the SNI-block bypass on', () {
    // The bypass applies only to a clean-IP fronted node, so this is the whole
    // reason the rewrite exists, not a side effect of it.
    final ProxyNode byName = node(
        'vless://00000000-0000-0000-0000-000000000001@sub.example.com:443'
        '?type=ws&security=tls&sni=sub.example.com&path=%2Fws#a');
    expect(byName.isCleanIpFronted, isFalse);

    final ProxyNode fronted = byName.copyWith(
        server: clean.ip, port: clean.port, sni: byName.sni ?? byName.server);
    expect(fronted.isCleanIpFronted, isTrue);

    // And the built config carries the bypass for the fronted one only.
    String tlsOf(ProxyNode n) => SingboxConfig.buildMap(n,
            options: const SingboxRouteOptions(hardenTls: true))
        .toString();
    expect(tlsOf(fronted), contains('cipher_suites'));
    expect(tlsOf(byName), isNot(contains('cipher_suites')));
  });

  group('the stored address', () {
    test('a fresh find is used', () {
      CleanIpStore.instance.hold(CleanIp(
        ip: '104.16.4.103',
        port: 443,
        latencyMs: 90,
        foundAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      expect(CleanIpStore.instance.fresh, isNotNull);
    });

    test('a stale one is not, because the network may have changed', () {
      CleanIpStore.instance.hold(CleanIp(
        ip: '104.16.4.103',
        port: 443,
        latencyMs: 90,
        foundAtMs: DateTime.now()
            .subtract(CleanIpStore.maxAge * 2)
            .millisecondsSinceEpoch,
      ));
      expect(CleanIpStore.instance.fresh, isNull);
      CleanIpStore.instance.hold(null);
    });
  });
}
