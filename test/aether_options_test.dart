import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';

/// Aether config settings: what the user picks, what the binary is told, and
/// what survives a share link.
///
/// The binary exits at startup on an unrecognised flag value, so a typo or a
/// value from a newer build must never reach it. When that happened with a uTLS
/// fingerprint, the core refused the whole config and every node in a measuring
/// pool went undialled, with nothing on screen to say why.
void main() {
  group('the command line matches what the binary accepts', () {
    test('a default MASQUE config', () {
      expect(const AetherOptions().toCliArgs(),
          <String>['--masque', '--scan', 'balanced', '-4']);
    });

    test('HTTP/2 with ClientHello fragmentation', () {
      const AetherOptions o = AetherOptions(
          transport: AetherTransport.h2, fragment: true, scan: AetherScan.turbo);
      expect(o.toCliArgs(),
          <String>['--masque', '--scan', 'turbo', '-4', '--h2', '--fragment']);
    });

    test('fragment is dropped when the transport cannot carry it', () {
      // --fragment is an HTTP/2 option. Passing it on HTTP/3 makes the binary
      // refuse to start, so a config with both set must still produce a command
      // line that runs.
      const AetherOptions o =
          AetherOptions(transport: AetherTransport.h3, fragment: true);
      expect(o.toCliArgs().contains('--fragment'), isFalse);
      expect(o.toCliArgs().contains('--h2'), isFalse);
    });

    test('WARP-in-WARP names both hops', () {
      const AetherOptions o = AetherOptions(
          mode: AetherMode.gool,
          wiwOuter: '162.159.192.1:2408',
          wiwInner: '188.114.96.1:2408');
      final List<String> a = o.toCliArgs();
      expect(a.first, '--gool');
      expect(a, containsAllInOrder(<String>['--wiw-outer', '162.159.192.1:2408']));
      expect(a, containsAllInOrder(<String>['--wiw-inner', '188.114.96.1:2408']));
    });

    test('no obfuscation flag is sent when none was chosen', () {
      // The binary picks firewall for MASQUE and balanced for the WireGuard
      // modes. Duplicating those defaults here would mean maintaining them in
      // two places and drifting when the binary changes them.
      expect(const AetherOptions().toCliArgs().contains('--noize'), isFalse);
      expect(
          const AetherOptions(noize: AetherNoize.gfw).toCliArgs(),
          containsAllInOrder(<String>['--noize', 'gfw']));
    });
  });

  group('a config survives being shared', () {
    test('every field round-trips', () {
      const AetherOptions o = AetherOptions(
        mode: AetherMode.gool,
        transport: AetherTransport.h2,
        ip: AetherIpMode.both,
        scan: AetherScan.ironclad,
        noize: AetherNoize.aggressive,
        peer: '1.2.3.4:443',
        wiwOuter: '5.6.7.8:2408',
        wiwInner: '9.10.11.12:2408',
        fragment: true,
        dns: '9.9.9.9',
      );
      final AetherOptions back = AetherOptions.decode(o.encode());
      expect(back.mode, o.mode);
      expect(back.ip, o.ip);
      expect(back.scan, o.scan);
      expect(back.noize, o.noize);
      expect(back.peer, o.peer);
      expect(back.wiwOuter, o.wiwOuter);
      expect(back.wiwInner, o.wiwInner);
      expect(back.fragment, o.fragment);
      expect(back.dns, o.dns);
    });

    test('an IPv6 endpoint survives', () {
      const AetherOptions o = AetherOptions(peer: '2606:4700:d0::a29f:c001:443');
      expect(AetherOptions.decode(o.encode()).peer, o.peer);
    });

    test('a value carrying the separators survives', () {
      // This is what the percent-encoding is actually for. Colons are safe on
      // their own, because decoding splits on the first '=' only, so an IPv6
      // address proves nothing about the encoding. A value containing '&' or
      // '=' is what would silently truncate the field and every field after it.
      const AetherOptions o = AetherOptions(dns: '1.1.1.1&x=2', peer: 'a=b&c');
      final AetherOptions back = AetherOptions.decode(o.encode());
      expect(back.dns, '1.1.1.1&x=2');
      expect(back.peer, 'a=b&c');
      expect(back.scan, AetherScan.balanced,
          reason: 'a raw & would end the field early and swallow what follows');
    });
  });

  group('a bad value never reaches the binary', () {
    test('an unknown mode falls back instead of being passed through', () {
      final AetherOptions o = AetherOptions.decode('mode=wormhole&scan=turbo');
      expect(o.mode, AetherMode.masque);
      expect(o.toCliArgs().contains('wormhole'), isFalse,
          reason: 'the binary exits on an unknown flag value, and the user '
              'would see a tunnel that never comes up and no reason why');
    });

    test('an unknown scan or obfuscation value falls back', () {
      final AetherOptions o = AetherOptions.decode('scan=ludicrous&noize=plaid');
      expect(o.scan, AetherScan.balanced);
      expect(o.noize, AetherNoize.firewall);
      expect(o.toCliArgs().join(' ').contains('ludicrous'), isFalse);
      expect(o.toCliArgs().join(' ').contains('plaid'), isFalse);
    });

    test('every emitted value is one the binary lists', () {
      // Guards the whole surface at once: if a new enum entry is added whose
      // name is not a real flag value, this fails without anyone remembering
      // to add a case.
      const Set<String> accepted = <String>{
        '--masque', '--wg', '--gool', '--scan', '--noize', '--peer',
        '--wiw-outer', '--wiw-inner', '--h2', '--fragment', '--dns',
        '-4', '-6', '--dual',
        'turbo', 'balanced', 'thorough', 'stealth', 'ironclad',
        'off', 'light', 'firewall', 'gfw', 'aggressive',
      };
      for (final AetherMode m in AetherMode.values) {
        for (final AetherScan s in AetherScan.values) {
          for (final AetherNoize n in AetherNoize.values) {
            for (final AetherIpMode ip in AetherIpMode.values) {
              final List<String> args =
                  AetherOptions(mode: m, scan: s, noize: n, ip: ip).toCliArgs();
              for (final String a in args) {
                expect(accepted.contains(a), isTrue,
                    reason: '"$a" is not a value the binary accepts');
              }
            }
          }
        }
      }
    });
  });

  test('the CPU-expensive transport is identified', () {
    // HTTP/3 measured 0.66 CPU-seconds per 20 MB against 0.37 for HTTP/2, so
    // the device tier needs to be able to ask which one this is.
    expect(const AetherOptions().isQuic, isTrue);
    expect(const AetherOptions(transport: AetherTransport.h2).isQuic, isFalse);
    expect(const AetherOptions(mode: AetherMode.wg).isQuic, isFalse);
  });
}
