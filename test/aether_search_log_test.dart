import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_search_log.dart';

/// The gateway search writes to the log the user is invited to export and paste
/// into a support thread. These are the two things that has to get right: the
/// line has to carry enough to diagnose a failure nobody can reproduce, and it
/// must never carry the WARP credential that sits in the same result map.
void main() {
  group('what a search result writes down', () {
    test('keeps the fields a refusal is diagnosed from', () {
      final String line = AetherSearchLog.fields(<String, dynamic>{
        'reachable': false,
        'ok': true,
        'reason': 'handshake timed out',
        'rtt_ms': 4821,
      });
      expect(line, contains('reachable=false'));
      expect(line, contains('reason=handshake timed out'));
      expect(line, contains('rtt_ms=4821'));
    });

    test('never writes a value whose name looks like a credential', () {
      const String warpKey = 'oPqRsTuVwXyZ0123456789abcdefghijklmnopqrstuvw=';
      final String line = AetherSearchLog.fields(<String, dynamic>{
        'private_key': warpKey,
        'session_token': 'abc123',
        'account_seed': 'xyz',
        'api_key': 'k',
        'secret': 's',
        'password': 'p',
      });
      expect(line, isNot(contains(warpKey)));
      expect(line, isNot(contains('abc123')));
      expect(line, isNot(contains('xyz')));
      for (final String named in <String>[
        'private_key',
        'session_token',
        'account_seed',
        'api_key',
        'secret',
        'password',
      ]) {
        expect(line, contains('$named=<hidden>'),
            reason: '$named must be named but not quoted');
      }
    });

    test('a long value is summarised rather than quoted', () {
      final String blob = 'A' * (AetherSearchLog.maxValue + 1);
      final String line =
          AetherSearchLog.fields(<String, dynamic>{'blob': blob});
      expect(line, isNot(contains(blob)));
      expect(line, contains('blob=<String>'));
    });

    test('a nested value is reported by name only', () {
      final String line = AetherSearchLog.fields(<String, dynamic>{
        'summary': <String, dynamic>{'private_key': 'leaked-through-nesting'},
      });
      expect(line, isNot(contains('leaked-through-nesting')));
      expect(line, isNot(contains('private_key')));
    });

    test('an empty or absent result is not an error', () {
      expect(AetherSearchLog.fields(null), '{}');
      expect(AetherSearchLog.fields(<String, dynamic>{}), '{}');
    });
  });

  test('settings name what the search actually ran with', () {
    const AetherOptions o = AetherOptions(
      mode: AetherMode.masque,
      transport: AetherTransport.h3,
      ip: AetherIpMode.v4,
      scan: AetherScan.balanced,
    );
    final String line = AetherSearchLog.settings(o);
    expect(line, contains('mode=masque'));
    expect(line, contains('transport=h3'));
    expect(line, contains('ip=v4'));
    expect(line, contains('scan=balanced'));
    // Unset obfuscation is the default the editor shows as Auto, and a log that
    // said nothing here would read as "not set" for a run that did have one.
    expect(line, contains('noize=auto'));
  });

  group('what a finished verification records', () {
    const String realIp = '5.106.77.201';

    test('a WARP exit address is kept, because that is the useful part', () {
      final Map<String, dynamic> m = AetherSearchLog.proof(
          viaWarp: true, warp: 'on', ip: '104.28.208.123', ms: 1600);
      expect(m['reachable'], isTrue);
      expect(m['warp'], 'on');
      expect(m['exit_ip'], '104.28.208.123');
    });

    // The one that matters. When traffic leaked around the tunnel, the address
    // the far end saw is the user's own, and this map goes into a log they are
    // invited to paste in public.
    test('the address is dropped when the traffic did not go through WARP', () {
      final Map<String, dynamic> m = AetherSearchLog.proof(
          viaWarp: false, warp: 'off', ip: realIp, ms: 812);
      expect(m.toString(), isNot(contains(realIp)));
      expect(m.containsKey('exit_ip'), isFalse);
      // Still diagnosable: we can tell a leak from a dead gateway.
      expect(m['warp'], 'off');
      expect(m['reachable'], isFalse);
    });

    test('a failure with no answer at all still says so', () {
      final Map<String, dynamic> m =
          AetherSearchLog.proof(viaWarp: false, ms: 20003);
      expect(m['reachable'], isFalse);
      expect(m.containsKey('warp'), isFalse);
      expect(m.containsKey('exit_ip'), isFalse);
      expect(m['ms'], 20003);
    });
  });

  group('core-supplied text', () {
    test('a subscription credential in an error is not logged', () {
      const String licence = 'k3Jd8Fq2';
      final String out = AetherSearchLog.scrub(
          'refused: {"license":"$licence","id":7}');
      expect(out, isNot(contains(licence)));
    });

    test('a key-shaped blob anywhere in a message is hidden', () {
      const String key = 'oPqRsTuVwXyZ0123456789abcdefghijklmnopqrstuvw';
      final String out =
          AetherSearchLog.scrub('handshake failed for peer $key at stage 2');
      expect(out, isNot(contains(key)));
      expect(out, contains('handshake failed'));
    });

    // Short words on purpose. A long run of one character is blob-shaped, so
    // the key scrubber shortens it and the truncation never gets tested, which
    // is how the first version of this passed against untruncated code.
    test('a core that prints a whole struct cannot fill the log', () {
      final String out =
          AetherSearchLog.scrub('failed to parse the field at index 4, ' * 200);
      expect(out.length, lessThanOrEqualTo(AetherSearchLog.maxError));
      expect(out, endsWith('...'));
    });

    test('an ordinary reason survives intact', () {
      expect(AetherSearchLog.scrub('connection refused'), 'connection refused');
      expect(AetherSearchLog.scrub(null), '');
    });
  });

  test('a subscription credential field name is covered', () {
    final String line = AetherSearchLog.fields(<String, dynamic>{
      'license': 'k3Jd8Fq2', 'credential': 'x', 'session_id': 'y',
    });
    expect(line, isNot(contains('k3Jd8Fq2')));
    expect(line, contains('license=<hidden>'));
  });
}
