import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// The shipped default finalmask.
///
/// Iran's DPI was changed on 2026-09-09 and the previous 5/94/1 plus 109/1
/// recipe stopped getting through. These are the values its author
/// published the same day. A tester in Iran confirmed they connect there and
/// that the old ones do not, so what ships as the default is the whole point:
/// most people never open the bypass editor.
///
/// The recipe is written twice, once as a JSON string for share links and once
/// as parsed stages for the config builder. Nothing but this test stops the two
/// from drifting apart, and a silent drift means the app sends one thing and
/// re-shares another.
void main() {
  const List<String> helloLengths = <String>['0', '104', '1'];
  const List<String> segmentLengths = <String>['114', '1'];

  Map<String, dynamic> stage(int i, String raw) =>
      ((jsonDecode(raw) as Map<String, dynamic>)['tcp'] as List<dynamic>)[i]
          ['settings'] as Map<String, dynamic>;

  test('the published values are what the string carries', () {
    expect(stage(0, kBypassFragmentMask)['lengths'], helloLengths);
    expect(stage(0, kBypassFragmentMask)['maxSplit'], '0');
    expect(stage(1, kBypassFragmentMask)['lengths'], segmentLengths);
    expect(stage(1, kBypassFragmentMask)['maxSplit'], '11',
        reason: 'the new recipe caps the segment split at 11, the old one 355');
  });

  test('the two copies of the recipe agree', () {
    // Reaching the parsed copy takes care. A node with no fm does NOT use it:
    // hardened() stamps the string onto the node first, so the builder reads
    // the node's own mask and the parsed copy stays untouched. Asserting on a
    // bare node therefore proves nothing about drift, which is exactly the
    // mistake this test was written with the first time.
    //
    // The parsed copy is the fallback for a mask that fails to parse, so an
    // unparseable fm is what actually exercises it.
    final ProxyNode bare = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
      '?security=tls&type=ws&sni=node.example.com'
      '&fm=${Uri.encodeComponent('not json at all')}#D',
    )!;
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(
      bare,
      options: const SingboxRouteOptions(hardenTls: true),
    );
    final Map<String, dynamic> tls =
        ((cfg['outbounds'] as List<dynamic>).first
            as Map<String, dynamic>)['tls'] as Map<String, dynamic>;
    final List<dynamic> emitted = tls['nova_fragment'] as List<dynamic>;

    final List<dynamic> fromString =
        (jsonDecode(kBypassFragmentMask) as Map<String, dynamic>)['tcp']
            as List<dynamic>;
    expect(emitted.length, fromString.length);
    for (int i = 0; i < emitted.length; i++) {
      expect(emitted[i], (fromString[i] as Map<String, dynamic>)['settings'],
          reason: 'stage $i differs between the string and the parsed copy');
    }
  });

  test('the superseded recipe is gone from both copies', () {
    // Named explicitly because the tester reported the app still sending the
    // old numbers, and a default is easy to change in one place only.
    expect(kBypassFragmentMask.contains('"94"'), isFalse);
    expect(kBypassFragmentMask.contains('"109"'), isFalse);
    expect(kBypassFragmentMask.contains('"355"'), isFalse);

    final ProxyNode bare = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
      '?security=tls&type=ws&sni=node.example.com#D',
    )!;
    final String cfg = jsonEncode(SingboxConfig.buildMap(
      bare,
      options: const SingboxRouteOptions(hardenTls: true),
    ));
    expect(cfg.contains('"94"'), isFalse);
    expect(cfg.contains('"109"'), isFalse);
    expect(cfg.contains('"355"'), isFalse);
  });

  test('a hardened node re-shares the new recipe', () {
    // The link Nova writes must carry the same values it dials with, or a
    // config shared out of Nova arrives with the superseded recipe.
    final ProxyNode hardened = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@node.example.com:443'
      '?security=tls&type=ws&sni=node.example.com#D',
    )!.hardened();
    expect(jsonDecode(hardened.fragmentMask!),
        jsonDecode(kBypassFragmentMask));
  });
}
