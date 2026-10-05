import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
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

  group('what afterConnect refuses to do', () {
    test('iOS is skipped, because the extension owns the path', () {
      expect(AetherRegistration.ownsRegistration(iOS: true), isFalse);
      expect(AetherRegistration.ownsRegistration(iOS: false), isTrue);
    });

    test('an Aether profile is skipped', () {
      expect(AetherRegistration.isAetherLink('aether://x?mode=wg'), isTrue);
      expect(AetherRegistration.isAetherLink('  AETHER://x  '), isTrue);
      expect(AetherRegistration.isAetherLink('vless://x'), isFalse);
      expect(AetherRegistration.isAetherLink('psiphon://aether'), isFalse);
      expect(AetherRegistration.isAetherLink(null), isFalse);
    });

    test('on iOS it reports the skip rather than attempting', () async {
      final ProxyProfile p = ProxyProfile(
          id: 'a', name: 'a', kind: ProxyKind.vless, uri: 'vless://x');
      expect(await AetherRegistration.afterConnect(p, iOS: true),
          AetherRegistrationSkip.iosExtension);
      // Same profile, not iOS: the guard is what stopped it, not the profile.
      expect(await AetherRegistration.afterConnect(p, iOS: false), isNull);
    });

    test('an Aether profile reports its own skip', () async {
      final ProxyProfile p = ProxyProfile(
          id: 'a', name: 'a', kind: ProxyKind.aether, uri: 'aether://x');
      expect(await AetherRegistration.afterConnect(p, iOS: false),
          AetherRegistrationSkip.aetherProfile);
    });
  });

  group('where each transport actually puts the registration', () {
    // Measured against the shipped core, because the two do not agree and the
    // difference was invisible: WireGuard writes the identity to the base path
    // exactly, with no suffix, while MASQUE writes it to base-masque.
    test('a WireGuard registration is found, suffix or no suffix', () {
      File(base()).writeAsStringSync('wireguard identity');
      expect(AetherRegistration.have(base()), isTrue,
          reason: 'only the suffixed form was checked, so a WireGuard '
              'registration read as none at all and Nova registered again on '
              'every connect for the life of the install');
    });

    test('an empty file at the base path is still not a registration', () {
      File(base()).writeAsStringSync('');
      expect(AetherRegistration.have(base()), isFalse);
    });

    test('a MASQUE registration is still found', () {
      File('${base()}-masque').writeAsStringSync('masque identity');
      expect(AetherRegistration.have(base()), isTrue);
    });

    test('a connection record at the base path is not mistaken for one', () {
      File('${base()}-lastconn').writeAsStringSync('connection record');
      expect(AetherRegistration.have(base()), isFalse);
    });
  });
}
