import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';

/// The editable ECH lookup, and the rule that "using the default" stays an
/// honest state rather than a copy of today's default frozen onto the profile.
void main() {
  ProxyProfile p({String? lookup}) => ProxyProfile(
        id: 'x',
        name: 'x',
        kind: ProxyKind.subscription,
        uri: 'https://example.com/sub',
        echSni: true,
        echConfigList: lookup,
      );

  test('an override survives a save and reload', () {
    const String custom = 'cloudflare-ech.com+udp://1.0.0.1';
    final ProxyProfile back = ProxyProfile.decodeList(
        ProxyProfile.encodeList(<ProxyProfile>[p(lookup: custom)])).single;
    expect(back.echConfigList, custom);
    expect(EchSpec.parse(back.echConfigList).resolver, 'udp://1.0.0.1');
  });

  test('no override stays no override, rather than becoming one', () {
    final ProxyProfile back = ProxyProfile.decodeList(
        ProxyProfile.encodeList(<ProxyProfile>[p()])).single;
    expect(back.echConfigList, isNull,
        reason: 'storing the default would freeze todays default onto the '
            'profile and quietly ignore a later change to it');
    expect(EchSpec.parse(back.echConfigList), EchSpec.fallback);
  });

  test('an override can be cleared back to the default', () {
    final ProxyProfile cleared =
        p(lookup: 'a.com+udp://9.9.9.9').copyWith(clearEchConfigList: true);
    expect(cleared.echConfigList, isNull);
    // copyWith without the flag must not clear it by accident, which is the
    // usual way an explicit-clear parameter goes wrong.
    expect(p(lookup: 'a.com+udp://9.9.9.9').copyWith(name: 'y').echConfigList,
        'a.com+udp://9.9.9.9');
  });

  test('the editor stores null for a lookup that is just the default', () {
    // Structural: the screen is a widget, but the rule is the whole point of
    // the field, and getting it backwards is how "default" turns into a frozen
    // copy of one.
    final String src =
        File('lib/src/features/servers/ech_editor_screen.dart').readAsStringSync();
    expect(src, contains('clearEchConfigList: true'));
    expect(src, contains('EchSpec.parse'));
    expect(src, isNot(contains('TextEditingController(text: EchSpec.fallback')),
        reason: 'prefilling the field with the default would make every save '
            'an override');
  });
}
