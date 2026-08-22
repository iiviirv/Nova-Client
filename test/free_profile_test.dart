import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';

/// The free server list Nova ships. Its whole promise is that someone can
/// install the app, press Connect, and be safe without reading a config, so the
/// two things that make that true are the two things worth pinning down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ProxyNode node(String link) => parseShareLink(link)!;

  Future<ProfilesController> controller(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    return ProfilesController()
      ..attachPrefs(await SharedPreferences.getInstance());
  }

  test('a fresh install starts with the free servers and them selected',
      () async {
    final ProfilesController c = await controller(<String, Object>{});
    expect(c.profiles.map((ProxyProfile p) => p.id), <String>[kFreeProfileId]);
    expect(c.activeId, kFreeProfileId,
        reason: 'install, press Connect, be online');
  });

  test('an upgrading user gets it too, without losing their selection',
      () async {
    final ProxyProfile mine = ProxyProfile(
        id: 'mine', name: 'Mine', kind: ProxyKind.vless, uri: 'vless://x@h:1');
    final ProfilesController c = await controller(<String, Object>{
      'nova.profiles': ProxyProfile.encodeList(<ProxyProfile>[mine]),
      'nova.profiles.active': 'mine',
    });
    expect(c.profiles.map((ProxyProfile p) => p.id),
        <String>[kFreeProfileId, 'mine']);
    expect(c.activeId, 'mine',
        reason: 'a built-in appearing must not take over their connection');
  });

  test('the free servers survive a restart', () async {
    final ProfilesController c = await controller(<String, Object>{});
    expect(c.hasFreeProfile, isTrue);
    final ProfilesController again = ProfilesController()
      ..attachPrefs(await SharedPreferences.getInstance());
    expect(again.hasFreeProfile, isTrue);
    expect(again.profiles, hasLength(1),
        reason: 'seeded once, not once per launch');
  });

  test('the free profile ships with the SNI bypass and the encryption filter',
      () {
    final ProxyProfile free = buildFreeProfile();
    expect(free.subscriptionUrl, kFreeSubUrl);
    expect(free.kind, ProxyKind.subscription);
    expect(free.hardenTls, isTrue,
        reason: 'the people who need a free list are on the blocking networks');
    expect(free.encryptedOnly, isTrue);
  });

  test('a plaintext server never survives into the free list', () {
    final List<ProxyNode> mixed = <ProxyNode>[
      // Encrypted: TLS on top.
      node('vless://00000000-0000-0000-0000-000000000001@a.example.net:443'
          '?type=ws&security=tls&sni=a.example.net&path=%2Fws#tls'),
      // Plaintext: VLESS over ws with no TLS at all.
      node('vless://00000000-0000-0000-0000-000000000002@b.example.net:80'
          '?type=ws&path=%2Fws#plain'),
      // Encrypted by the protocol itself, with no TLS layer.
      node('hysteria2://pw@c.example.net:2090#hy2'),
    ];
    final List<ProxyNode> kept =
        applyProfileFilters(buildFreeProfile(), mixed);
    expect(kept.map((ProxyNode n) => n.tag), <String>['tls', 'hy2']);
  });

  test("a user's own subscription is never filtered", () {
    final ProxyProfile mine = ProxyProfile(
      id: 'mine',
      name: 'Mine',
      kind: ProxyKind.subscription,
      uri: 'https://example.net/sub',
      subscriptionUrl: 'https://example.net/sub',
    );
    final List<ProxyNode> plain = <ProxyNode>[
      node('vless://00000000-0000-0000-0000-000000000002@b.example.net:80'
          '?type=ws&path=%2Fws#plain'),
    ];
    expect(applyProfileFilters(mine, plain), hasLength(1));
  });

  group('the free list is not the user\'s to delete', () {
    test('remove() refuses it, and a user profile still deletes', () async {
      final ProxyProfile mine = ProxyProfile(
          id: 'mine', name: 'Mine', kind: ProxyKind.vless, uri: 'vless://x@h:1');
      final ProfilesController c = await controller(<String, Object>{});
      c.add(mine);
      expect(c.hasFreeProfile, isTrue);
      c.remove(kFreeProfileId);
      expect(c.hasFreeProfile, isTrue,
          reason: 'the one thing someone with nothing can fall back to');
      c.remove('mine');
      expect(c.profiles.map((ProxyProfile p) => p.id), <String>[kFreeProfileId]);
    });

    test('only the built-in list is protected', () {
      expect(buildFreeProfile().isBuiltIn, isTrue);
      expect(
          ProxyProfile(
                  id: 'mine',
                  name: 'Mine',
                  kind: ProxyKind.vless,
                  uri: 'vless://x@h:1')
              .isBuiltIn,
          isFalse);
    });
  });

  test('a server that is merely down is not filtered out of the list', () {
    // Hiding it is a view decision taken from the current measurement (see the
    // node list). Doing it here would mean the next sweep only ever sees the
    // survivors, and one unlucky run shrinks the list for good.
    final List<ProxyNode> n = <ProxyNode>[
      node('hysteria2://p@a.example.net:443#a'),
      node('hysteria2://p@b.example.net:443#b'),
    ];
    expect(applyProfileFilters(buildFreeProfile(), n), hasLength(2));
  });

  test('encryptedOnly survives a save and load', () {
    final ProxyProfile back = ProxyProfile.decodeList(
        ProxyProfile.encodeList(<ProxyProfile>[buildFreeProfile()])).single;
    expect(back.encryptedOnly, isTrue);
    expect(back.hardenTls, isTrue);
    expect(back.id, kFreeProfileId);
  });
}
