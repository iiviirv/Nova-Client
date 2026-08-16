import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/xray/xray_config.dart';

/// A VLESS-over-xhttp link, the transport sing-box cannot run at all.
const String _xhttpLink =
    'vless://00000000-0000-4000-8000-000000000000@104.17.5.5:443'
    '?encryption=none&security=tls&type=xhttp'
    '&sni=azure.example.workers.dev&host=azure.example.workers.dev'
    '&path=%2Fxh#XhttpNode';

void main() {
  test('an xhttp VLESS node translates to a valid Xray config', () {
    final ProxyNode n = parseShareLink(_xhttpLink)!;
    expect(n.network, 'xhttp');
    final Map<String, dynamic> cfg = XrayConfig.buildMap(n, socksPort: 38080);

    final List<dynamic> inb = cfg['inbounds'] as List<dynamic>;
    expect((inb.first as Map)['protocol'], 'socks');
    expect((inb.first as Map)['port'], 38080);

    final Map<String, dynamic> out =
        (cfg['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
    expect(out['protocol'], 'vless');
    final Map<String, dynamic> stream =
        out['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'tls');
    expect((stream['xhttpSettings'] as Map)['path'], '/xh');
    expect((stream['tlsSettings'] as Map)['serverName'],
        'azure.example.workers.dev');
    final Map<String, dynamic> vnext =
        ((out['settings'] as Map)['vnext'] as List<dynamic>).first
            as Map<String, dynamic>;
    expect(vnext['address'], '104.17.5.5');
    expect(((vnext['users'] as List).first as Map)['id'],
        '00000000-0000-4000-8000-000000000000');

    // Emit the config so the Xray core wrapper's Go test can load the CLIENT's
    // real output and prove the core accepts it (the full round-trip).
    File('${Directory.systemTemp.path}/nova_xray_spike.json')
        .writeAsStringSync(jsonEncode(cfg));
  });

  test('non-xhttp / non-VLESS is rejected (sing-box owns those)', () {
    final ProxyNode ws = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@1.2.3.4:443'
      '?encryption=none&security=tls&type=ws&host=h&path=%2Fp#W',
    )!;
    expect(() => XrayConfig.buildMap(ws), throwsFormatException);
  });
}
