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
  _loopPrevention();
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

  group('the share format matches the other clients byte for byte', () {
    // Captured from real links exported by another client on 2026-09-14. These
    // are the contract: a config shared out of Nova must import there, and
    // theirs here. Guessing this format wrong would have been invisible until
    // someone tried to move a config between the two apps.
    const String masque =
        'aether://162.159.198.1:443?protocol=masque&scan=balanced'
        '&noize=balanced&ip=v4&transport=h3#masque%20add%20test';
    const String wg =
        'aether://162.159.195.150:908?protocol=wg&scan=balanced'
        '&noize=balanced&ip=v4#wire%20add%20test';
    const String gool =
        'aether://?protocol=gool&scan=balanced&noize=balanced&ip=v4'
        '&outer=162.159.195.16%3A864&inner=162.159.192.1%3A2408'
        '#gool%20add%20test';

    test('a MASQUE link parses', () {
      final AetherConfig c = AetherConfig.parse(masque)!;
      expect(c.options.mode, AetherMode.masque);
      expect(c.options.transport, AetherTransport.h3);
      expect(c.options.scan, AetherScan.balanced);
      expect(c.options.noize, AetherNoize.balanced);
      expect(c.options.ip, AetherIpMode.v4);
      expect(c.gateway, '162.159.198.1:443');
      expect(c.name, 'masque add test');
    });

    test('a WireGuard link parses and carries no transport', () {
      final AetherConfig c = AetherConfig.parse(wg)!;
      expect(c.options.mode, AetherMode.wg);
      expect(c.gateway, '162.159.195.150:908');
      expect(c.toLink().contains('transport='), isFalse,
          reason: 'transport is a MASQUE-only key and they do not write it');
    });

    test('a gool link has no authority and names both hops', () {
      final AetherConfig c = AetherConfig.parse(gool)!;
      expect(c.options.mode, AetherMode.gool);
      expect(c.gateway, isNull, reason: 'gool scans, the hops are in the query');
      expect(c.options.wiwOuter, '162.159.195.16:864');
      expect(c.options.wiwInner, '162.159.192.1:2408');
    });

    test('all three re-serialise to the exact original string', () {
      for (final String link in <String>[masque, wg, gool]) {
        expect(AetherConfig.parse(link)!.toLink(), link,
            reason: 'a config that changes when shared is a config that stops '
                'importing into the client it came from');
      }
    });

    test('a link Nova wrote itself round-trips', () {
      const AetherConfig c = AetherConfig(
          name: 'my exit',
          options: AetherOptions(
              mode: AetherMode.masque,
              transport: AetherTransport.h2,
              scan: AetherScan.thorough,
              noize: AetherNoize.gfw,
              peer: '1.2.3.4:443'));
      final AetherConfig back = AetherConfig.parse(c.toLink())!;
      expect(back.options.transport, AetherTransport.h2);
      expect(back.options.noize, AetherNoize.gfw);
      expect(back.gateway, '1.2.3.4:443');
      expect(back.name, 'my exit');
    });

    test('a non-aether link is declined so other parsers get a turn', () {
      expect(AetherConfig.parse('vless://x@1.2.3.4:443'), isNull);
      expect(AetherConfig.parse('not a link'), isNull);
    });
  });

  group('a bad value never reaches the binary', () {
    test('an unknown mode falls back instead of being passed through', () {
      final AetherOptions o = AetherOptions.fromQuery('protocol=wormhole&scan=turbo');
      expect(o.mode, AetherMode.masque);
      expect(o.toCliArgs().contains('wormhole'), isFalse,
          reason: 'the binary exits on an unknown flag value, and the user '
              'would see a tunnel that never comes up and no reason why');
    });

    test('an unknown scan or obfuscation value falls back', () {
      final AetherOptions o = AetherOptions.fromQuery('scan=ludicrous&noize=plaid');
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

/// The ranges that must escape the tunnel, and why.
void _loopPrevention() {
  group('the scan ranges escape the tunnel', () {
    test('every gateway seen in a real shared config is covered', () {
      // The three links another client exported name these gateways. If a
      // range were missing, that config would connect there and nowhere else,
      // which is exactly the kind of gap that looks like "sometimes one IP
      // does not work".
      const List<String> seen = <String>[
        '162.159.198.1', // masque
        '162.159.195.150', // wireguard
        '162.159.195.16', // gool outer
        '162.159.192.1', // gool inner
      ];
      for (final String ip in seen) {
        final String slash24 =
            '${ip.substring(0, ip.lastIndexOf('.'))}.0/24';
        expect(kAetherDirectCidrs.contains(slash24), isTrue,
            reason: '$ip would be captured by the tunnel and loop');
      }
    });

    test('both address families are covered', () {
      expect(kAetherDirectCidrs.any((String c) => c.contains(':')), isTrue,
          reason: 'a v6 config would loop with only v4 ranges listed');
      expect(kAetherDirectCidrs.any((String c) => !c.contains(':')), isTrue);
    });

    test('every entry is a well-formed CIDR', () {
      for (final String c in kAetherDirectCidrs) {
        expect(c.contains('/'), isTrue, reason: '$c has no prefix length');
        final int bits = int.parse(c.split('/').last);
        expect(bits > 0 && bits <= 128, isTrue, reason: '$c has a bad prefix');
      }
    });
  });
}
