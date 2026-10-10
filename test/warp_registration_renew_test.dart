import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_registration.dart';

/// Field report, 2026-10-10. A registration was taken through a tunnel that was
/// up but carrying nothing. The log said it was saved. From then on WARP could
/// never connect, and because a file existed the call was skipped on every
/// later attempt, including after connecting to a server that worked. The only
/// way out was to reinstall the app.
///
/// "Even when I connected to a healthy server afterwards it never tried to get
/// the key again, even though the key was broken."
///
/// So a saved registration has to be disposable. One that does not work is
/// worse than none: none at least gets replaced.
void main() {
  late Directory tmp;
  late String base;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nova-warp-');
    base = '${tmp.path}/aether';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String name, String body) =>
      File('${tmp.path}/$name').writeAsStringSync(body);

  test('both transports are thrown away, whatever they named their file', () {
    // WireGuard writes to the base exactly, MASQUE to base-masque. Measured
    // against the shipped core, not assumed.
    write('aether', 'wg identity');
    write('aether-masque', 'masque identity');
    write('aether-masque-lastconn', 'timestamp');
    expect(AetherRegistration.have(base), isTrue);

    expect(AetherRegistration.forget(base), 3);
    expect(AetherRegistration.have(base), isFalse,
        reason: 'and now the next connection will take a new one');
  });

  test('a neighbouring file that is not a registration is left alone', () {
    write('aether-masque', 'masque identity');
    write('aetherwards', 'not ours');
    write('other', 'not ours');
    expect(AetherRegistration.forget(base), 1);
    expect(File('${tmp.path}/aetherwards').existsSync(), isTrue,
        reason: 'only names under the prefix plus a dash belong to us');
    expect(File('${tmp.path}/other').existsSync(), isTrue);
  });

  test('forgetting nothing is not an error', () {
    expect(AetherRegistration.forget(base), 0);
    expect(AetherRegistration.forget('${tmp.path}/gone/aether'), 0,
        reason: 'a directory that does not exist is not a crash');
  });

  test('have and forget agree about what counts as a registration', () {
    // They read the same files, so a disagreement would mean forget leaves
    // behind exactly the thing that keeps have saying yes, which is the bug
    // this exists to prevent.
    for (final String name in <String>['aether', 'aether-masque']) {
      write(name, 'x');
      expect(AetherRegistration.have(base), isTrue, reason: name);
      AetherRegistration.forget(base);
      expect(AetherRegistration.have(base), isFalse, reason: name);
    }
  });

  test('an empty file was never a registration and is still removed', () {
    write('aether-masque', '');
    expect(AetherRegistration.have(base), isFalse,
        reason: 'have requires a non-empty file');
    expect(AetherRegistration.forget(base), 1,
        reason: 'and forget clears it anyway, so a zero-byte leftover cannot '
            'sit there confusing the next person');
  });
}
