import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_registration.dart';

/// A tester's suggestion, and the clean answer to a problem that had no clean
/// answer: when a network blocks Cloudflare's registration, WARP can never
/// start there, and the only remedy anyone had was "connect on a different
/// network once". But Nova is often already connected through something that
/// works, a free server or the user's own. While that tunnel is up the
/// registration call goes through it. Take it then, and the blocked network
/// never has to be solved at all.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('warp-reg-'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String base() => AetherRegistration.baseIn(dir);

  test('a fresh device has no registration', () {
    expect(AetherRegistration.have(base()), isFalse);
  });

  test('a saved registration is found', () {
    File('${base()}-wg').writeAsStringSync('registration');
    expect(AetherRegistration.have(base()), isTrue);
  });

  test('either transport counts, since one is enough to prove it works', () {
    File('${base()}-masque').writeAsStringSync('registration');
    expect(AetherRegistration.have(base()), isTrue);
  });

  test('a connection record is not a registration', () {
    // The core writes aether-wg-lastconn beside the registration. Mistaking it
    // for one would skip the registration and leave WARP unable to start.
    File('${base()}-wg-lastconn').writeAsStringSync('last gateway');
    expect(AetherRegistration.have(base()), isFalse);
  });

  test('an empty file is not a registration', () {
    // A half-written file from an interrupted attempt must not count, or the
    // device is stuck with something unusable and never tries again.
    File('${base()}-wg').writeAsStringSync('');
    expect(AetherRegistration.have(base()), isFalse);
  });

  test('an existing registration is reported as present', () async {
    File('${base()}-wg').writeAsStringSync('registration');
    expect(await AetherRegistration.ensure(base: base()), isTrue);
  });

  // Note, found by mutation: deleting the early return in ensure() does not
  // fail any test here, because the final have() check reports the same answer
  // either way. That is honest rather than a gap. The early return only avoids
  // spending a request that would change nothing, so its absence is wasteful,
  // not wrong, and proving it would mean injecting the core to count calls for
  // a guard whose failure costs one request on an already working connection.

  test('unrelated files in the directory are ignored', () {
    File('${dir.path}/masterdns.json').writeAsStringSync('{}');
    File('${dir.path}/aetherish').writeAsStringSync('x');
    expect(AetherRegistration.have(base()), isFalse);
  });
}
