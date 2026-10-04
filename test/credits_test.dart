import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Shipping Aether (AGPL-3.0) and the Psiphon engine (GPL-3.0) without their
/// notices is a licence breach, and the app did exactly that until this screen
/// existed. The test is structural because the failure is an absence: a credit
/// that is deleted, or a core added later with no entry, is not something any
/// behavioural test of the screen would notice.
void main() {
  final String screen =
      File('lib/src/features/settings/credits_screen.dart').readAsStringSync();
  final String strings =
      File('lib/src/l10n/nova_strings.dart').readAsStringSync();

  for (final String name in <String>[
    'Aether',
    'PattNG',
    'Psiphon',
    'sing-box',
    'Xray-core',
  ]) {
    test('$name is credited', () {
      expect(screen, contains("'$name'"),
          reason: '$name is shipped in the app but no longer credited');
    });
  }

  for (final String licence in <String>['AGPL-3.0', 'GPL-3.0', 'MPL-2.0']) {
    test('$licence is named', () => expect(screen, contains(licence)));
  }

  test('the screen is reachable from Settings', () {
    expect(File('lib/src/features/settings/settings_screen.dart')
        .readAsStringSync(), contains('CreditsScreen()'),
        reason: 'a credits screen nothing opens is not a credit');
  });

  test('every credits string is translated into Farsi', () {
    final RegExp keys = RegExp(r"'(credits\.[a-zA-Z]+)'");
    final Set<String> ids =
        keys.allMatches(strings).map((m) => m.group(1)!).toSet();
    expect(ids, isNotEmpty);
    final int faAt = strings.indexOf('_fa = <String, String>{');
    final String fa = strings.substring(faAt);
    for (final String id in ids) {
      expect(fa, contains("'$id':"), reason: '$id has no Farsi translation');
    }
  });
}
