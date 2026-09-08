import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Moving the free list to a new published URL without stranding anyone.
///
/// The list is about to be published with no addresses in it, which older
/// clients cannot read: they would dial 127.0.0.1. So the new list goes to a
/// new URL and the old one keeps real addresses until nobody is fetching it.
///
/// The trap that makes this necessary: the free profile is seeded ONCE and then
/// persisted, and nothing rewrote a seeded profile afterwards. Changing the URL
/// in code would therefore have reached new installs only. Every existing user
/// would have gone on fetching the old list forever, while we believed we had
/// moved them. A no-op that looks like a successful release.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProfilesController> withStored(List<ProxyProfile> profiles) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nova.profiles': ProxyProfile.encodeList(profiles),
      // Already seeded, so the controller loads rather than creating fresh.
      'nova.freeSeeded': true,
    });
    final ProfilesController c = ProfilesController();
    c.attachPrefs(await SharedPreferences.getInstance());
    return c;
  }

  ProxyProfile freeAt(String url) => ProxyProfile(
        id: kFreeProfileId,
        name: 'Nova free servers',
        kind: ProxyKind.subscription,
        uri: url,
        subscriptionUrl: url,
        hardenTls: true,
      );

  test('an existing install is moved to the new list', () async {
    final ProfilesController c = await withStored(<ProxyProfile>[
      freeAt(kFreeSubUrlLegacy),
    ]);
    final ProxyProfile free =
        c.profiles.firstWhere((ProxyProfile p) => p.id == kFreeProfileId);
    expect(free.subscriptionUrl, kFreeSubUrl,
        reason: 'without this the URL change reaches new installs only, and we '
            'would think we had shipped it to everyone');
    expect(free.uri, kFreeSubUrl);
  });

  test('the move is written to disk, not just held in memory', () async {
    await withStored(<ProxyProfile>[freeAt(kFreeSubUrlLegacy)]);
    final SharedPreferences p = await SharedPreferences.getInstance();
    expect(p.getString('nova.profiles'), contains('sub-v2.txt'),
        reason: 'a migration that does not persist runs again every launch and '
            'is undone by anything that writes first');
  });

  test('a profile already on the new list is left alone', () async {
    final ProfilesController c =
        await withStored(<ProxyProfile>[freeAt(kFreeSubUrl)]);
    expect(
        c.profiles
            .firstWhere((ProxyProfile p) => p.id == kFreeProfileId)
            .subscriptionUrl,
        kFreeSubUrl);
  });

  test("a URL the user pointed somewhere else is NOT taken over", () async {
    // Someone who edited the free profile to use their own list chose that.
    const String mine = 'https://example.com/my-own-list.txt';
    final ProfilesController c = await withStored(<ProxyProfile>[freeAt(mine)]);
    expect(
        c.profiles
            .firstWhere((ProxyProfile p) => p.id == kFreeProfileId)
            .subscriptionUrl,
        mine,
        reason: 'only the URL Nova published is ours to move');
  });

  test('other profiles are untouched', () async {
    final ProxyProfile other = ProxyProfile(
      id: 'other',
      name: 'Paid sub',
      kind: ProxyKind.subscription,
      uri: kFreeSubUrlLegacy,
      subscriptionUrl: kFreeSubUrlLegacy,
    );
    final ProfilesController c =
        await withStored(<ProxyProfile>[freeAt(kFreeSubUrlLegacy), other]);
    expect(
        c.profiles
            .firstWhere((ProxyProfile p) => p.id == 'other')
            .subscriptionUrl,
        kFreeSubUrlLegacy,
        reason: 'the migration is keyed on the free profile, not on the URL, so '
            'a coincidence of addresses cannot move somebody else');
  });

  test('the two URLs are actually different', () {
    // Guards the whole feature against a copy-paste that would make the
    // migration a no-op and every test above pass for the wrong reason.
    expect(kFreeSubUrl, isNot(kFreeSubUrlLegacy));
  });
}
