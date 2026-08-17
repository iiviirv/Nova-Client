import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';

/// The AmneziaWG core parses the peer Endpoint with ParseAddr and rejects a
/// hostname, so the client must resolve a domain endpoint to an IP first. These
/// cover the pure host extract/rewrite helpers the controller uses.
const String _conf = '''
[Interface]
PrivateKey = qMYgTEYybL/RSMCwsgl7itAkqbspP/p04E5x48cWj3k=
Address = 10.13.13.8/32
Jc = 4
[Peer]
PublicKey = cXWZR4R9frmafME3LHqSpY2XLMcA5Ffu5Q2NyiYj4j8=
Endpoint = vpn.novaproxy.qzz.io:51820
AllowedIPs = 0.0.0.0/0, ::/0
''';

void main() {
  test('awgEndpointHost extracts the domain', () {
    expect(awgEndpointHost(_conf), 'vpn.novaproxy.qzz.io');
    expect(awgEndpointHost('[Interface]\nPrivateKey = x'), isNull);
  });

  test('rewriteAwgEndpointHost swaps the host, keeps the port', () {
    final String out = rewriteAwgEndpointHost(_conf, '145.223.80.159');
    expect(out.contains('Endpoint = 145.223.80.159:51820'), isTrue);
    expect(out.contains('vpn.novaproxy.qzz.io'), isFalse);
    // The parsed endpoint now carries the IP the core needs.
    expect(AwgConfig.parseConf(out).peer.host, '145.223.80.159');
    expect(AwgConfig.parseConf(out).peer.port, 51820);
  });

  test('rewrite brackets an IPv6 endpoint', () {
    final String out = rewriteAwgEndpointHost(_conf, '2001:db8::1');
    expect(out.contains('Endpoint = [2001:db8::1]:51820'), isTrue);
  });
}
