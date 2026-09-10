import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The mask the user typed is the mask that gets sent.
///
/// Iran's DPI was updated on 2026-09-09 and the previously working finalmask
/// values stopped getting through. new ones were published the same day, and
/// its author's advice was simply "change the finalMask values". In Nova that
/// did nothing, and there were two separate reasons.
///
/// The first was that a domain-addressed node was never hardened at all (fixed
/// in v1.23.1). This is the second, and the likelier one for anyone whose
/// configs came from another bypass client: those share links carry their own
/// `fm=`, which
/// made the node count as already hardened, so hardened() returned it untouched
/// and the stale mask from the link was sent instead of the typed one.
///
/// Neither failure said anything on screen. The app showed the new values in
/// the editor while sending the old ones.
void main() {
  const String linkFm =
      '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
      '"lengths":["7","77","1"],"delays":["0"],"maxSplit":"0"}}]}';
  const String typedFm =
      '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
      '"lengths":["0","104","1"],"delays":["0"],"maxSplit":"0"}}]}';

  // 77 is the link's own value, 104 is what the user types, and Nova's
  // built-in default is 94. All three differ on purpose: when the link's mask
  // matched the default, "the default silently replaced it" looked identical to
  // "the link kept its own" and the regression was invisible.
  ProxyNode pattNgLink({String? fm}) => parseShareLink(
        'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
        '?security=tls&type=ws&sni=node.example.com'
        '${fm == null ? '' : '&fm=${Uri.encodeComponent(fm)}'}#P',
      )!;

  String cfg(ProxyNode n, {String? typed, String? fingerprint}) =>
      jsonEncode(SingboxConfig.buildMap(
        n,
        options: SingboxRouteOptions(
          hardenTls: true,
          bypassFragmentMask: typed,
          bypassFingerprint: fingerprint,
        ),
      ));

  test('a typed mask replaces the one baked into the link', () {
    final String s = cfg(pattNgLink(fm: linkFm), typed: typedFm);
    expect(s.contains('"104"'), isTrue,
        reason: 'the user typed this one into the bypass editor');
    expect(s.contains('"77"'), isFalse,
        reason: 'the stale mask from the link must not survive the edit');
  });

  test('with nothing typed, the link keeps its own mask', () {
    // Someone who never opened the editor should not have a config provider's
    // tuned values quietly replaced by Nova's generic default.
    final String s = cfg(pattNgLink(fm: linkFm));
    expect(s.contains('"77"'), isTrue,
        reason: "the config provider's own tuned value must survive");
    expect(s.contains('"104"'), isFalse);
    expect(s.contains('"94"'), isFalse,
        reason: "Nova's built-in default must not quietly replace it either");
  });

  test('a link with no mask still gets the typed one', () {
    final String s = cfg(pattNgLink(), typed: typedFm);
    expect(s.contains('"104"'), isTrue);
  });

  test('a typed cipher list also outranks the link', () {
    // Same early return, same silent discard: the cipher list is handed to
    // hardened() on the call the link short-circuited.
    final String s = jsonEncode(SingboxConfig.buildMap(
      pattNgLink(fm: linkFm),
      options: const SingboxRouteOptions(
        hardenTls: true,
        bypassCipherSuites: <String>['TLS_AES_128_GCM_SHA256'],
      ),
    ));
    expect(s.contains('TLS_AES_128_GCM_SHA256'), isTrue);
    expect(s.contains('TLS_CHACHA20_POLY1305_SHA256'), isFalse,
        reason: 'the default list must not be merged back in');
  });

  test('a hardened node sends no browser fingerprint, by design', () {
    // Worth pinning because the bypass editor offers a fingerprint chooser
    // whose value cannot reach this branch: `fp=unsafe` means Go's own TLS with
    // the given cipher list, so uTLS is off whenever the bypass is on. If that
    // ever changes, it should be a decision, not a surprise.
    final String s = cfg(pattNgLink(fm: linkFm), typed: typedFm);
    expect(s.contains('"utls":{"enabled":false}'), isTrue);
  });
}
