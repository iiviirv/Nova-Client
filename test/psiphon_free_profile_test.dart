import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';

/// Tester's asks after build 167, which connected: ship a Psiphon through WARP
/// profile by default, and put every Psiphon profile in the Free list however
/// it was made.
void main() {
  _namingAndBadge();
  test('the shipped Psiphon profile rides on WARP, not direct', () {
    final ProxyProfile p = buildFreePsiphonProfile();
    expect(p.kind, ProxyKind.psiphon);
    expect(PsiphonConfig.modeFromLink(p.uri), PsiphonMode.throughAether,
        reason: 'Psiphon does not reach its network from inside Iran unaided; '
            'a direct default would ship a profile that cannot connect there');
  });

  test('it carries no WARP config of its own', () {
    // The app supplies the carrier, so the profile stays valid however the
    // user's WARP profiles change.
    expect(PsiphonConfig.viaLinkFrom(buildFreePsiphonProfile().uri), isNull);
  });

  test('it is a built-in free option, so it cannot be deleted by accident', () {
    expect(buildFreePsiphonProfile().isBuiltInFreeOption, isTrue);
  });

  test('every Psiphon profile lives in Free, seeded or user-made', () {
    final ProxyProfile mine = ProxyProfile(
      id: 'mine',
      name: 'My Psiphon',
      kind: ProxyKind.psiphon,
      uri: PsiphonConfig.linkFor(PsiphonMode.direct),
    );
    expect(mine.isFreeOption, isTrue,
        reason: 'it carries no server of the user\'s, so Subscriptions, which '
            'is where things someone gave you live, is the wrong place');
    expect(buildFreePsiphonProfile().isFreeOption, isTrue);
  });

  test('it does not collide with the three WARP profiles', () {
    final Set<String> ids = <String>{
      for (final ProxyProfile p in buildFreeAetherProfiles()) p.id,
      buildFreePsiphonProfile().id,
    };
    expect(ids, hasLength(4));
  });
}

/// A tester asked for the two shapes to be tellable apart: named by mode, and
/// with the cores they run on visible, since a chained Psiphon uses two.
void _namingAndBadge() {
  test('the shipped profile says which shape it is', () {
    expect(buildFreePsiphonProfile().name, 'Psiphon WARP');
  });

  test('a chained profile names both cores on its badge', () {
    final ProxyProfile chained = ProxyProfile(
        id: 'a',
        name: 'Psiphon WARP',
        kind: ProxyKind.psiphon,
        uri: PsiphonConfig.linkFor(PsiphonMode.throughAether));
    expect(chained.badgeLabel.toLowerCase(), contains('psiphon'));
    expect(chained.badgeLabel.toLowerCase(), contains('aether'),
        reason: 'which cores it runs on is not guessable from the name');
  });

  test('a direct profile names only Psiphon, because that is all it uses', () {
    final ProxyProfile direct = ProxyProfile(
        id: 'b',
        name: 'Psiphon Direct',
        kind: ProxyKind.psiphon,
        uri: PsiphonConfig.linkFor(PsiphonMode.direct));
    expect(direct.badgeLabel.toLowerCase(), contains('psiphon'));
    expect(direct.badgeLabel.toLowerCase(), isNot(contains('aether')));
  });
}
