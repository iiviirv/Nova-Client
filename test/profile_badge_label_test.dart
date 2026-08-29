import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';

/// The AmneziaWG version belongs on the badge everywhere a config appears, not
/// only inside a subscription's node list. A pasted `.conf` is its own profile,
/// so it never reaches that list, and the tester who reported a 2.0 server
/// labelled version 1 was looking at exactly this badge.
void main() {
  const String base = '''
[Interface]
PrivateKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Address = 10.0.0.2/32
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 574
H1 = 1
H2 = 2
H3 = 3
H4 = 4
''';
  const String peer = '''

[Peer]
PublicKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
''';

  ProxyProfile awg(String conf) => ProxyProfile(
        id: 'p',
        name: 'awg',
        kind: ProxyKind.awg,
        uri: conf,
      );

  test('version 1', () => expect(awg(base + peer).badgeLabel, 'AmneziaWG ver 1'));

  test('version 2', () {
    expect(awg('$base\nS3 = 45\nS4 = 12\n$peer').badgeLabel, 'AmneziaWG ver 2');
  });

  test('version 3', () {
    expect(awg('$base\nS3 = 45\nS4 = 12\nHeaderProtectionKey = abc\n$peer').badgeLabel,
        'AmneziaWG ver 3');
  });

  test('plain WireGuard keeps the plain badge', () {
    expect(
        awg('[Interface]\nPrivateKey = IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=\n'
                'Address = 10.0.0.2/32\n$peer')
            .badgeLabel,
        'AmneziaWG');
  });

  test('every other protocol is untouched', () {
    expect(
        ProxyProfile(id: 'v', name: 'v', kind: ProxyKind.vless, uri: 'vless://x')
            .badgeLabel,
        'VLESS');
    expect(
        ProxyProfile(
                id: 's',
                name: 's',
                kind: ProxyKind.subscription,
                uri: '',
                subscriptionUrl: 'https://example.com/sub')
            .badgeLabel,
        'Subscription');
  });
}
