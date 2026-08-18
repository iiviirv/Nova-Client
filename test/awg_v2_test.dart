import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// A full AmneziaWG **v2** config: the v1 junk (Jc/Jmin/Jmax, S1/S2, H1-H4) plus
/// the v2 additions S3/S4 and the I1-I5 special-junk packet templates. This is
/// the shape a v2 panel hands out.
const String _awgV2Conf = '''
[Interface]
PrivateKey = QFX3M2b0m3n0m3n0m3n0m3n0m3n0m3n0m3n0m3n0k0=
Address = 10.13.13.2/32
DNS = 1.1.1.1
Jc = 4
Jmin = 40
Jmax = 70
S1 = 30
S2 = 40
S3 = 50
S4 = 60
H1 = 1234567890
H2 = 1234567891
H3 = 1234567892
H4 = 1234567893
I1 = <b 0xf1c0><c><t><r 20>
I2 = <b 0xe2><r 10>
I3 = <b 0xd3><r 15>
I4 = <b 0xc4><r 25>
I5 = <b 0xb5><r 5>
[Peer]
PublicKey = mZ0m3n0m3n0m3n0m3n0m3n0m3n0m3n0m3n0m3n0k0=
PresharedKey = pZ0m3n0m3n0m3n0m3n0m3n0m3n0m3n0m3n0m3n0k0=
Endpoint = 188.114.96.1:51820
AllowedIPs = 0.0.0.0/0
''';

void main() {
  test('an AmneziaWG v2 config parses every v2 junk parameter', () {
    final AwgConfig c = AwgConfig.parseConf(_awgV2Conf);
    expect(c.isObfuscated, isTrue);
    expect(c.jc, 4);
    expect(<int?>[c.s1, c.s2, c.s3, c.s4], <int>[30, 40, 50, 60]);
    expect(<String?>[c.h1, c.h2, c.h3, c.h4],
        <String>['1234567890', '1234567891', '1234567892', '1234567893']);
    // The v2 special-junk templates must survive verbatim.
    expect(c.i1, '<b 0xf1c0><c><t><r 20>');
    expect(c.i5, '<b 0xb5><r 5>');
  });

  test('the built endpoint carries all v2 params to the core', () {
    final ProxyNode node = ProxyNode.fromAwgConf(_awgV2Conf, name: 'AWG v2');
    final Map<String, dynamic> cfg = SingboxConfig.buildMap(node);
    final List<dynamic> eps = cfg['endpoints'] as List<dynamic>;
    expect(eps, isNotEmpty, reason: 'AmneziaWG builds as an endpoint');
    final Map<String, dynamic> ep = eps.first as Map<String, dynamic>;
    // Every v2 knob must be present in the endpoint the core receives.
    expect(ep['jc'], 4);
    expect(ep['s3'], 50);
    expect(ep['s4'], 60);
    expect(ep['i1'], '<b 0xf1c0><c><t><r 20>');
    expect(ep['i5'], '<b 0xb5><r 5>');
    expect(ep['h4'], '1234567893');

    // Emit the config so the core `check` can be run against a real v2 endpoint.
    final Directory out = Directory.systemTemp;
    File('${out.path}/nova_awg_v2_check.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
    // ignore: avoid_print
    print('wrote ${out.path}/nova_awg_v2_check.json');
  });
}
