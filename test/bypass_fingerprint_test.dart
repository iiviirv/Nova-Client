import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The fingerprint chosen in the bypass editor is the one that gets sent.
///
/// The editor offers `unsafe` plus every browser profile the core accepts, but
/// the bypass branch switched uTLS off unconditionally. Picking Firefox stored
/// Firefox, displayed Firefox, and sent Go's own ClientHello. A control that
/// changes nothing, and the third instance of that shape found in this area
/// after the two finalmask bugs.
///
/// Fragmentation is what defeats the SNI match and does not depend on the
/// hello, so a browser profile and fragmentation combine: the patched core
/// wraps the uTLS path with nova_fragment the same way it wraps the plain one
/// (see novafrag.patch, UTLSClientConfig.Client).
void main() {
  ProxyNode node() => parseShareLink(
        'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
        '?security=tls&type=ws&sni=node.example.com#F',
      )!;

  Map<String, dynamic> tlsOf(String? fp) {
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(
      node(),
      options: SingboxRouteOptions(hardenTls: true, bypassFingerprint: fp),
    );
    final List<dynamic> out = cfg['outbounds'] as List<dynamic>;
    return ((out.first as Map<String, dynamic>)['tls'] as Map<String, dynamic>);
  }

  test('a chosen browser profile is actually forged', () {
    final Map<String, dynamic> tls = tlsOf('firefox');
    final Map<String, dynamic> utls = tls['utls'] as Map<String, dynamic>;
    expect(utls['enabled'], isTrue);
    expect(utls['fingerprint'], 'firefox');
  });

  test('and it still fragments, which is what defeats the SNI match', () {
    expect(tlsOf('firefox').containsKey('nova_fragment'), isTrue,
        reason: 'the core wraps the uTLS path with novafrag too, so choosing a '
            'browser must not cost the fragmentation');
  });

  test('a browser profile drops the cipher list it cannot honour', () {
    // uTLS builds the hello from the profile, cipher list included.
    expect(tlsOf('firefox').containsKey('cipher_suites'), isFalse);
  });

  test('unsafe keeps Go TLS with the cipher list, as before', () {
    final Map<String, dynamic> tls = tlsOf('unsafe');
    expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse);
    expect(tls.containsKey('cipher_suites'), isTrue);
    expect(tls.containsKey('nova_fragment'), isTrue);
  });

  test('the default is unchanged for anyone who never opened the editor', () {
    // hardened() stamps 'unsafe' when the profile names no fingerprint, so the
    // shipped behaviour must be identical to explicitly choosing unsafe.
    expect(jsonEncode(tlsOf(null)), jsonEncode(tlsOf('unsafe')));
  });

  test('a fingerprint the core does not know does not become Go TLS', () {
    // _singboxFingerprint maps an unknown value onto chrome. The important part
    // is that it stays a forged hello rather than silently falling back to the
    // unsafe path, which would be a different handshake than asked for.
    final Map<String, dynamic> utls =
        tlsOf('nonesuch')['utls'] as Map<String, dynamic>;
    expect(utls['enabled'], isTrue);
    expect(utls['fingerprint'], 'chrome');
  });

  test('a custom mask does not rob the node of the unsafe default', () {
    // The ordering trap, hit while writing this fix. Applying the profile's
    // overrides before hardened() gives the node a fragmentMask, which makes it
    // count as already hardened, so hardened() declines to stamp its defaults
    // and a link that pinned fp=chrome kept Chrome instead of getting the
    // 'unsafe' the bypass means. The visible damage was the cipher list
    // vanishing, because a browser hello drops it.
    const String customMask =
        '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
        '"lengths":["3","7"],"delays":["0"],"maxSplit":"0"}}]}';
    final ProxyNode pinned = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
      '?security=tls&type=ws&sni=node.example.com&fp=chrome#C',
    )!;
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(
      pinned,
      options: const SingboxRouteOptions(
        hardenTls: true,
        bypassFragmentMask: customMask,
      ),
    );
    final Map<String, dynamic> tls =
        ((cfg['outbounds'] as List<dynamic>).first
            as Map<String, dynamic>)['tls'] as Map<String, dynamic>;
    expect((tls['utls'] as Map<String, dynamic>)['enabled'], isFalse,
        reason: 'turning the bypass on means unsafe unless the user picked a '
            'browser, whatever the link pinned');
    expect(tls.containsKey('cipher_suites'), isTrue);
  });
}
