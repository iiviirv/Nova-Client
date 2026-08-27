import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';

/// AmneziaWG 3.x adds header protection, content padding and randomised
/// timings on top of the 2.0 obfuscation. They travel as plain strings: a hex
/// key, and "min-max" ranges.
///
/// The one trap is that the core refuses the whole device when header
/// protection is asked for with S1-S4 below 12 ("S%d must be more then %d to
/// use headerProtection"). A tunnel that will not start is worse than one
/// without header protection, so the key is withheld rather than handed over.
void main() {
  String conf({String extra = '', int s = 86}) => '''
[Interface]
PrivateKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Address = 10.0.0.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = $s
S2 = $s
S3 = $s
S4 = $s
H1 = 180583858
H2 = 720512096
H3 = 1677969799
H4 = 1808982857
$extra

[Peer]
PublicKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

  const String v3 = '''
HeaderProtectionKey = 0123456789abcdef0123456789abcdef
ContentPaddingAddition = 16-64
RekeyAfterTime = 100-140
RekeyTimeout = 5-8
RejectAfterTime = 160-200
KeepaliveTimeout = 8-12
MaxHandshakeAttempts = 10-20''';

  test('a 2.0 config emits exactly what it always did', () {
    final Map<String, dynamic> e =
        AwgConfig.parseConf(conf()).toEndpoint('awg');
    final String j = jsonEncode(e);
    for (final String k in <String>[
      'header_protection_key',
      'content_padding_addition',
      'rekey_after_time',
      'rekey_timeout',
      'reject_after_time',
      'keepalive_timeout',
      'max_handshake_attempts',
    ]) {
      expect(j.contains(k), isFalse, reason: '$k must not appear for a 2.0 config');
    }
    expect(e['jc'], 4);
  });

  test('a 3.x config carries every new parameter through', () {
    final Map<String, dynamic> e =
        AwgConfig.parseConf(conf(extra: v3)).toEndpoint('awg');
    expect(e['header_protection_key'], '0123456789abcdef0123456789abcdef');
    expect(e['content_padding_addition'], '16-64');
    expect(e['rekey_after_time'], '100-140');
    expect(e['rekey_timeout'], '5-8');
    expect(e['reject_after_time'], '160-200');
    expect(e['keepalive_timeout'], '8-12');
    expect(e['max_handshake_attempts'], '10-20');
    // The 2.0 parameters are untouched.
    expect(e['jc'], 4);
    expect(e['h1'], '180583858');
  });

  test('header protection is withheld when the padding is too small', () {
    final AwgConfig c = AwgConfig.parseConf(conf(extra: v3, s: 8));
    expect(c.headerProtectionUsable, isFalse);
    final Map<String, dynamic> e = c.toEndpoint('awg');
    expect(e.containsKey('header_protection_key'), isFalse,
        reason: 'the core would refuse the whole device');
    // Everything else still goes, so the config is not wasted.
    expect(e['content_padding_addition'], '16-64');
    expect(e['rekey_timeout'], '5-8');
  });

  test('padding exactly at the minimum is allowed', () {
    final AwgConfig c = AwgConfig.parseConf(conf(extra: v3, s: 12));
    expect(c.headerProtectionUsable, isTrue);
    expect(c.toEndpoint('awg')['header_protection_key'], isNotNull);
  });
}
