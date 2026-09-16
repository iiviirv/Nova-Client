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
}
