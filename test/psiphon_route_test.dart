import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';
import 'package:nova_client/src/l10n/nova_strings.dart';

/// The editor existed for a while with nothing that opened it, so the feature
/// was unreachable from the running app. These pin the two ways in.
void main() {
  test('both languages name the entry and say what it asks for', () {
    for (final Locale l in <Locale>[const Locale('en'), const Locale('fa')]) {
      final NovaStrings s = NovaStrings(l);
      expect(s.psiphonAdd, isNotEmpty);
      expect(s.psiphonAddSub, isNotEmpty);
      // A key that was never translated falls through as the key itself.
      expect(s.psiphonAdd, isNot(contains('psiphon.add')));
      expect(s.psiphonAddSub, isNot(contains('psiphon.addSub')));
    }
  });

  test('the Persian entry isolates the Latin name so it reads correctly', () {
    final NovaStrings fa = NovaStrings(const Locale('fa'));
    for (final String text in <String>[fa.psiphonAdd, fa.psiphonAddSub]) {
      if (text.contains('Psiphon')) {
        expect(text, contains('\u2066'), reason: 'missing LRI');
        expect(text, contains('\u2069'), reason: 'missing PDI');
      }
    }
  });

  test('a saved Psiphon profile is recognised as one to reopen in the editor',
      () {
    final ProxyProfile p = ProxyProfile(
      id: 'p1',
      name: 'Psiphon',
      kind: ProxyKind.psiphon,
      uri: PsiphonConfig.linkFor(PsiphonMode.direct),
    );
    expect(p.kind, ProxyKind.psiphon);
    expect(PsiphonConfig.modeFromLink(p.uri), isNotNull,
        reason: 'the edit route reopens the editor from this link');
  });
}
