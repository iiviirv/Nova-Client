import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';

/// The server list shows which AmneziaWG generation a server offers, because
/// "it connects but carries nothing" and "your server is older than your app"
/// look identical from the outside, and version 3 is the whole point of the
/// recent work.
///
/// There is no version field in a WireGuard config, so this reads the settings
/// each version introduced.
void main() {
  String conf({String extra = ''}) => '''
[Interface]
PrivateKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Address = 10.0.0.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 574
S3 = 45
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
$extra

[Peer]
PublicKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

  test('header protection means version 3', () {
    expect(awgVersionLabel(conf(extra: 'HeaderProtectionKey = abc')), '3');
  });

  test('any other version 3 setting counts too', () {
    expect(awgVersionLabel(conf(extra: 'RekeyTimeout = 5-8')), '3');
    expect(awgVersionLabel(conf(extra: 'ContentPaddingAddition = 16-64')), '3');
    expect(awgVersionLabel(conf(extra: 'MaxHandshakeAttempts = 10-20')), '3');
  });

  test('signature packets mean version 2', () {
    expect(awgVersionLabel(conf(extra: 'I1 = <b 0xf1>')), '2');
  });

  test('version 3 wins when a config carries both', () {
    expect(
        awgVersionLabel(conf(extra: 'I1 = <b 0xf1>\nHeaderProtectionKey = abc')),
        '3');
  });

  test('junk packets and headers alone claim no version', () {
    expect(awgVersionLabel(conf()), isNull,
        reason: 'guessing a number is worse than showing none');
  });

  test('nothing, or an unparsable config, is not an error', () {
    expect(awgVersionLabel(null), isNull);
    expect(awgVersionLabel(''), isNull);
    expect(awgVersionLabel('not a config at all'), isNull);
  });
}
