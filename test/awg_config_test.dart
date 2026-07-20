import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

// A real AmneziaWG client config emitted by the Nova node agent.
const String _realConf = '''
[Interface]
PrivateKey = 2KYL5T3gG734Gc/bTlv31krekZ5K8Q2yJQlmDmKN+Vo=
Address = 10.13.13.3/32
DNS = 1.1.1.1, 1.0.0.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 86
S2 = 574
H1 = 677389858
H2 = 1150488281
H3 = 718829454
H4 = 1896311101

[Peer]
PublicKey = cXWZR4R9frmafME3LHqSpY2XLMcA5Ffu5Q2NyiYj4j8=
Endpoint = 145.223.80.159:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

void main() {
  test('parses the node .conf into the sing-box awg endpoint', () {
    final AwgConfig c = AwgConfig.parseConf(_realConf);
    expect(c.isObfuscated, isTrue);
    expect(c.privateKey, '2KYL5T3gG734Gc/bTlv31krekZ5K8Q2yJQlmDmKN+Vo=');
    expect(c.address, <String>['10.13.13.3/32']);
    expect(c.dns, <String>['1.1.1.1', '1.0.0.1']);
    expect(c.jc, 4);
    expect(c.h1, '677389858');
    expect(c.peer.host, '145.223.80.159');
    expect(c.peer.port, 51820);
    expect(c.peer.allowedIps, <String>['0.0.0.0/0', '::/0']);
    expect(c.peer.keepalive, 25);

    final Map<String, dynamic> ep = c.toEndpoint('awg-out');
    // Matches hiddify option/awg.go: type awg, h* are strings, peer uses
    // preshared_key/address/port/persistent_keepalive_interval.
    expect(ep['type'], 'awg');
    expect(ep['tag'], 'awg-out');
    expect(ep['jc'], 4);
    expect(ep['h1'], '677389858');
    expect(ep['address'], <String>['10.13.13.3/32']);
    final Map<String, dynamic> peer =
        (ep['peers'] as List<dynamic>).first as Map<String, dynamic>;
    expect(peer['public_key'], 'cXWZR4R9frmafME3LHqSpY2XLMcA5Ffu5Q2NyiYj4j8=');
    expect(peer['address'], '145.223.80.159');
    expect(peer['port'], 51820);
    expect(peer['persistent_keepalive_interval'], 25);
    expect(peer.containsKey('preshared_key'), isFalse);
  });

  test('round-trips through the flattened param map', () {
    final AwgConfig a = AwgConfig.parseConf(_realConf);
    final AwgConfig b = AwgConfig.fromParams(a.toParams());
    expect(b.toEndpoint('x'), a.toEndpoint('x'));
  });

  test('parses a plain WireGuard conf with a preshared key (no junk)', () {
    const String wg = '''
[Interface]
PrivateKey = aGVsbG8=
Address = 10.0.0.2/32, fd00::2/128
MTU = 1408

[Peer]
PublicKey = d29ybGQ=
PresharedKey = c2VjcmV0
Endpoint = [2606:4700::1]:2408
AllowedIPs = 0.0.0.0/0
''';
    final AwgConfig c = AwgConfig.parseConf(wg);
    expect(c.isObfuscated, isFalse);
    expect(c.mtu, 1408);
    expect(c.address, <String>['10.0.0.2/32', 'fd00::2/128']);
    expect(c.peer.host, '2606:4700::1'); // bracketed IPv6
    expect(c.peer.port, 2408);
    final Map<String, dynamic> ep = c.toEndpoint('wg');
    expect(ep.containsKey('jc'), isFalse); // plain WG: no junk fields
    final Map<String, dynamic> peer =
        (ep['peers'] as List<dynamic>).first as Map<String, dynamic>;
    expect(peer['preshared_key'], 'c2VjcmV0');
  });

  test('looksLikeConf detects a config vs a share link', () {
    expect(AwgConfig.looksLikeConf(_realConf), isTrue);
    expect(AwgConfig.looksLikeConf('vless://abc@host:443'), isFalse);
  });

  test('rejects an incomplete config', () {
    expect(() => AwgConfig.parseConf('[Interface]\nAddress = 10.0.0.2/32'),
        throwsA(isA<FormatException>()));
  });

  test('ProxyNode.fromAwgConf sets server/port from the peer endpoint', () {
    final ProxyNode n = ProxyNode.fromAwgConf(_realConf, name: 'My AWG');
    expect(n.protocol, NodeProtocol.awg);
    expect(n.protocol.isEndpoint, isTrue);
    expect(n.protocol.isUdpNative, isTrue);
    expect(n.server, '145.223.80.159');
    expect(n.port, 51820);
    expect(n.tag, 'My AWG');
  });

  test('buildMap emits an awg endpoint tagged proxy and routes to it', () {
    final ProxyNode n = ProxyNode.fromAwgConf(_realConf);
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(n);

    // The awg node is an endpoint, not an outbound.
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    expect(outs.any((dynamic o) => o['tag'] == 'proxy'), isFalse);
    expect(outs.any((dynamic o) => o['tag'] == 'direct'), isTrue);

    final List<dynamic> eps = cfg['endpoints'] as List<dynamic>;
    expect(eps, hasLength(1));
    final Map<String, dynamic> ep = eps.first as Map<String, dynamic>;
    expect(ep['type'], 'awg');
    expect(ep['tag'], 'proxy'); // routing/dns target this tag
    expect(ep['jc'], 4);
    expect(ep['h1'], '677389858');

    // UDP-native, so QUIC must NOT be blocked.
    final List<dynamic> rules =
        (cfg['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    final bool blocksQuic = rules.any((dynamic r) =>
        (r as Map<String, dynamic>)['protocol'] == 'quic' &&
        r['outbound'] == 'block');
    expect(blocksQuic, isFalse);
  });
}
