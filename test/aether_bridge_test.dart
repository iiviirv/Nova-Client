import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The core config that forwards into the Aether core.
///
/// The shape is copied from a config another client exports: a plain socks
/// outbound to a local port, with none of the Aether settings in it. What that
/// config does NOT have is any rule keeping the Aether core's own dial out of
/// the tunnel, because it runs a socks inbound where nothing is captured. Nova
/// runs a tunnel, so the absence there is not a licence to omit it here.
void main() {
  Map<String, dynamic> cfg({SingboxRouteOptions? o}) =>
      SingboxConfig.buildAetherSocksBridgeMap(19819,
          options: o ?? const SingboxRouteOptions());

  List<dynamic> rulesOf(Map<String, dynamic> c) =>
      (c['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;

  group('the outbound points at the local core', () {
    test('proxy is socks5 on the port we were given', () {
      final Map<String, dynamic> out =
          ((cfg()['outbounds'] as List<dynamic>).first) as Map<String, dynamic>;
      expect(out['type'], 'socks');
      expect(out['tag'], 'proxy');
      expect(out['server'], '127.0.0.1');
      expect(out['server_port'], 19819);
      expect(out['version'], '5');
    });

    test('no gateway address appears in the config at all', () {
      // The gateway is the Aether core's business. If one leaked in here it
      // would mean sing-box was trying to speak SOCKS to a Cloudflare edge.
      final String s = jsonEncode(cfg()['outbounds']);
      expect(s.contains('162.159'), isFalse);
      expect(s.contains('188.114'), isFalse);
    });
  });

  group('the core can reach an edge from inside its own tunnel', () {
    test('the WARP ranges are pinned to direct', () {
      final Map<String, dynamic> first =
          rulesOf(cfg()).first as Map<String, dynamic>;
      expect(first['outbound'], 'direct');
      expect(first['ip_cidr'], kAetherDirectCidrs);
    });

    test('that rule is first, so nothing later steers it back', () {
      // Order is the whole mechanism. A direct rule placed after a
      // proxy-everything rule is not a weaker fix, it is no fix.
      final List<dynamic> r = rulesOf(cfg());
      final int direct = r.indexWhere((dynamic x) =>
          (x as Map<String, dynamic>)['ip_cidr'] == kAetherDirectCidrs);
      expect(direct, 0);
    });

    test('registration is resolved and routed outside the tunnel', () {
      // First run registers an identity against this host. Resolving it inside
      // a tunnel that does not exist yet cannot work.
      final String route = jsonEncode(cfg()['route']);
      expect(route, contains(kAetherRegistrationHost));
      final String dns = jsonEncode(cfg()['dns']);
      expect(dns, contains(kAetherRegistrationHost));
    });

    test('QUIC is not blocked, because MASQUE is QUIC', () {
      // The xhttp bridge blocks UDP/443 since its exit is TCP. Copying that
      // here would leave HTTP/2 working and HTTP/3 silently dead, which is the
      // harder failure to diagnose of the two.
      // The rule sing-box actually emits is {"protocol":"quic","outbound":
      // "block"}, confirmed by dumping both bridges rather than assuming a
      // shape. The first version of this test guessed port/network and passed
      // whether or not QUIC was blocked.
      final bool blocked = rulesOf(cfg()).any((dynamic r) {
        final Map<String, dynamic> m = r as Map<String, dynamic>;
        return m['protocol'] == 'quic' && m['outbound'] == 'block';
      });
      expect(blocked, isFalse,
          reason: 'blocking QUIC would leave HTTP/2 working and HTTP/3 dead');
    });
  });
}
