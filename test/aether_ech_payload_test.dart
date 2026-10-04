import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_env.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_registration.dart';

/// The v2.3.0 core can hide its own handshakes behind ECH, which is the fix at
/// source for the fault build 174 works around: on some networks the Cloudflare
/// registration is blocked outright, and WARP cannot start without it.
///
/// Two things measured in the core's own source shape these tests:
///   - It fetches no ECH key for a WireGuard transport, so asking there can
///     only fail.
///   - When it is asked for ECH and cannot get a key it fails the job with
///     NO_ECH_KEY rather than continuing unencrypted. Asking is therefore not
///     free, and every ECH attempt needs a plain one behind it.
void main() {
  Map<String, dynamic> decode(String s) =>
      jsonDecode(s) as Map<String, dynamic>;

  test('off by default, so no payload changes shape unasked', () {
    const AetherOptions o = AetherOptions();
    expect(o.ech, isFalse);
    expect(decode(AetherPayloads.identity(o, base: '/tmp/a')).containsKey('ech'),
        isFalse);
    expect(
        decode(AetherPayloads.tunnel(o,
                endpoint: '1.2.3.4:443', socks: '127.0.0.1:1'))
            .containsKey('ech'),
        isFalse);
  });

  test('on, every job that can use it carries it', () {
    const AetherOptions o = AetherOptions(ech: true);
    expect(decode(AetherPayloads.identity(o, base: '/tmp/a'))['ech'], isTrue);
    expect(decode(AetherPayloads.scan(o))['ech'], isTrue);
    expect(
        decode(AetherPayloads.tunnel(o,
            endpoint: '1.2.3.4:443', socks: '127.0.0.1:1'))['ech'],
        isTrue);
  });

  test('registration tries ECH then plain, for MASQUE only', () {
    final List<AetherOptions> masque =
        AetherRegistration.attemptsForTest(AetherMode.masque);
    expect(masque.map((AetherOptions o) => o.ech), <bool>[true, false],
        reason: 'a failed ECH attempt must not leave WARP unregistered');

    final List<AetherOptions> wg =
        AetherRegistration.attemptsForTest(AetherMode.wg);
    expect(wg.map((AetherOptions o) => o.ech), <bool>[false],
        reason: 'the core fetches no ECH key for WireGuard, so asking only '
            'turns a working call into NO_ECH_KEY');
  });

  test('the resolver is DoH, not the core default that gets blocked', () {
    // The core defaults to udp://1.1.1.1, which is exactly what the networks
    // this feature is for block. Plain DNS over TCP on 53 is as blockable.
    expect(AetherEnv.kEchDns, startsWith('https://'));
    expect(AetherEnv.kEchDns, isNot(contains('udp://')));
    // By address, so resolving the resolver is not a prerequisite.
    expect(AetherEnv.kEchDns, matches(RegExp(r'^https://\d+\.\d+\.\d+\.\d+/')));
  });

  test('setting the variable actually works on this platform', () {
    // Platform.environment is a snapshot and cannot be written, so this goes
    // through libc. If that ever stops working the core silently falls back to
    // its UDP default, which is the failure this names.
    AetherEnv.apply();
    expect(AetherEnv.appliedForTest, isTrue);
  });
}
