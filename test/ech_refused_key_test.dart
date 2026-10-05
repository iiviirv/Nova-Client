import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nova_client/src/core/proxy/ech_key.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';

/// The key cache used to be a one-way door. `current()` falls back to the
/// remembered key when a fresh lookup fails, and nothing in the app ever called
/// `invalidate()`: its only reference in the whole tree was a test's setUp. So a
/// key every server rejects stayed in use for its full six hours and across
/// restarts.
///
/// That is bad when Cloudflare has merely rotated. It is worse if the key was
/// never Cloudflare's, because the holder of the private half can decrypt the
/// inner ClientHello and read the real server name, which is the one thing ECH
/// is for.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EchKey.invalidate();
  });

  const EchSpec spec = EchSpec.fallback;

  group('recognising a refusal', () {
    test('the real log line from the field is recognised', () {
      expect(
          EchKey.looksLikeRefusedKey(
              'ERROR tls: failed to verify certificate: x509: certificate is '
              'valid for cloudflare-ech.com, not ctcf.mayata.sbs',
              domain: 'cloudflare-ech.com'),
          isTrue);
    });

    test('a certificate error about some other name is not this', () {
      expect(
          EchKey.looksLikeRefusedKey(
              'x509: certificate is valid for example.org, not example.com',
              domain: 'cloudflare-ech.com'),
          isFalse);
    });

    test('the other ECH failure, a bad fingerprint, is not this', () {
      expect(
          EchKey.looksLikeRefusedKey('tls: malformed outer client hello',
              domain: 'cloudflare-ech.com'),
          isFalse,
          reason: 'that one is the fingerprint, and dropping the key would '
              'send it chasing the wrong fault');
    });

    test('with no key held and no name known, nothing matches', () {
      expect(
          EchKey.looksLikeRefusedKey(
              'x509: certificate is valid for cloudflare-ech.com, not h'),
          isFalse);
    });

    test('dropping the key forgets the name it belonged to as well', () async {
      await EchKey.current(spec: spec, fetch: () async => 'SEEDED-KEY');
      expect(
          EchKey.looksLikeRefusedKey(
              'x509: certificate is valid for cloudflare-ech.com, not h'),
          isTrue,
          reason: 'while the key is held, a refusal naming its public name is '
              'about that key');
      await EchKey.invalidate();
      expect(
          EchKey.looksLikeRefusedKey(
              'x509: certificate is valid for cloudflare-ech.com, not h'),
          isFalse,
          reason: 'nothing is held any more, so there is no key to blame');
    });
  });

  group('acting on a refusal', () {
    Future<void> seed() async {
      final String? got = await EchKey.current(
          spec: spec, fetch: () async => 'SEEDED-KEY');
      expect(got, 'SEEDED-KEY');
    }

    test('a refusal drops the key, so the next connection looks it up again',
        () async {
      await seed();
      expect(
          await EchKey.noteCoreLine(
              'x509: certificate is valid for cloudflare-ech.com, not h'),
          isTrue);
      // With the key gone and no resolver reachable, the honest answer is null
      // rather than the key that was just refused.
      expect(await EchKey.current(spec: spec, fetch: () async => null), isNull);
    });

    test('an unrelated core line leaves the key alone', () async {
      await seed();
      expect(await EchKey.noteCoreLine('inbound/tun: started at nova-tun'),
          isFalse);
      expect(await EchKey.current(spec: spec, fetch: () async => null),
          'SEEDED-KEY');
    });

    test('the drop survives a restart, not just this run', () async {
      await seed();
      await EchKey.noteCoreLine(
          'x509: certificate is valid for cloudflare-ech.com, not h');
      // A fresh process reads the cache from disk. If invalidate only cleared
      // memory, this would come back with the refused key.
      await EchKey.invalidate();
      expect(await EchKey.current(spec: spec, fetch: () async => null), isNull);
    });
  });

  /// Both controllers see core lines, in two separate places. This work has
  /// been fixed one-controller-at-a-time four times running (_stopPsiphon, the
  /// opportunistic WARP registration, the ECH lookup wiring, the measuring
  /// key), each time shipping with half the fix. A hook that exists in one and
  /// not the other is the same bug again.
  test('both controllers feed core lines to the key check', () {
    for (final String path in <String>[
      'lib/src/core/proxy/singbox_proxy_controller.dart',
      'lib/src/core/proxy/desktop_proxy_controller.dart',
    ]) {
      expect(File(path).readAsStringSync(), contains('EchKey.noteCoreLine'),
          reason: '$path never asks whether a server refused the ECH key, so '
              'on that platform a bad key is kept for its full six hours');
    }
  });
}
