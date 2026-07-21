import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/relay/relay_link.dart';

void main() {
  test('encode -> decode round-trips relay + tunnel fields', () {
    const RelayLinkData d = RelayLinkData(
      execUrl: 'https://script.google.com/macros/s/ABC/exec',
      authKey: 'k3y_-_value',
      allowInsecure: true,
      frontEnabled: true,
      frontSni: 'www.google.com',
      frontIp: '216.239.38.120',
      tunnelUrl: 'https://145.223.80.159/tunnel',
      tunnelKey: 'tunkey',
      tunnelPort: 1080,
      name: 'My Relay',
    );
    final String link = d.encode();
    expect(link.startsWith('nova-relay://'), isTrue);

    final RelayLinkData? out = RelayLinkData.decode(link);
    expect(out, isNotNull);
    expect(out!.execUrl, d.execUrl);
    expect(out.authKey, d.authKey);
    expect(out.allowInsecure, isTrue);
    expect(out.frontEnabled, isTrue);
    expect(out.frontSni, 'www.google.com');
    expect(out.frontIp, '216.239.38.120');
    expect(out.hasTunnel, isTrue);
    expect(out.tunnelUrl, d.tunnelUrl);
    expect(out.tunnelPort, 1080);
    expect(out.name, 'My Relay');
  });

  test('a minimal link (url only) works and defaults the rest', () {
    final String link =
        const RelayLinkData(execUrl: 'https://x/exec').encode();
    final RelayLinkData out = RelayLinkData.decode(link)!;
    expect(out.execUrl, 'https://x/exec');
    expect(out.allowInsecure, isFalse);
    expect(out.frontEnabled, isFalse);
    expect(out.hasTunnel, isFalse);
  });

  test('decode rejects non-relay text and garbage', () {
    expect(RelayLinkData.decode('vless://abc@h:443'), isNull);
    expect(RelayLinkData.decode('nova-relay://not-base64!!!'), isNull);
    expect(RelayLinkData.decode('nova-relay://'), isNull);
    expect(RelayLinkData.looksLike('nova-relay://xyz'), isTrue);
    expect(RelayLinkData.looksLike('https://x/sub'), isFalse);
  });
}
