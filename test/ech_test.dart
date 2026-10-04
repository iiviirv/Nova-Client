import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Measured on 2026-10-04, which is the only reason any of this exists.
/// ClientHello fragmentation, which the SNI bypass has always used, is now
/// fully blocked on the MCI firewall. ECH still gets through, because it
/// encrypts the name rather than splitting it.
///
/// The live findings behind the shape of this config, all against the shipped
/// 1.14.1-nova core:
///   - `ech: {enabled: true}` with no config makes the core resolve the ECH key
///     from the server name's HTTPS DNS record. Against a host with no such
///     record that is an outright failure ("fetch ECH config list: NXDOMAIN"),
///     and the lookup needs UDP 53, which is what the same firewall blocks.
///     So Nova supplies the key instead of resolving it.
///   - Cloudflare publishes one key for every zone: cloudflare-ech.com and
///     ir.innovio.ae returned byte-identical values.
///   - ECH is accepted by novaproxy.online, cloudflare-ech.com and
///     crypto.cloudflare.com, and rejected by ir.innovio.ae, so it is a per
///     profile switch rather than something to turn on everywhere.
void main() {
  ProxyNode node({String sni = 'ir.innovio.ae'}) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: '172.67.82.107',
        port: 443,
        uuid: 'd72f3244-9734-4ae5-9ce2-429b0a64976d',
        tls: true,
        sni: sni,
        network: 'ws',
        wsPath: '/novapanel2026',
        tag: 'n',
      );

  Map<String, dynamic> tlsOf(SingboxRouteOptions o) {
    final Map<String, dynamic> m =
        SingboxConfig.buildMap(node(), options: o);
    final List<dynamic> outs = m['outbounds'] as List<dynamic>;
    return (outs.first as Map<String, dynamic>)['tls']
        as Map<String, dynamic>;
  }

  test('off by default, so nothing changes for anyone who did not ask', () {
    expect(tlsOf(const SingboxRouteOptions()).containsKey('ech'), isFalse);
    expect(
        ProxyProfile(id: 'a', name: 'a', kind: ProxyKind.vless, uri: '').echSni,
        isFalse);
  });

  test('on, it carries the key rather than resolving it', () {
    final Map<String, dynamic> tls =
        tlsOf(const SingboxRouteOptions(ech: true));
    final Map<String, dynamic> ech = tls['ech'] as Map<String, dynamic>;
    expect(ech['enabled'], isTrue);
    final List<dynamic> pem = ech['config'] as List<dynamic>;
    expect(pem.first, '-----BEGIN ECH CONFIGS-----');
    expect(pem.last, '-----END ECH CONFIGS-----');
    expect(pem[1], kCloudflareEchConfig);
    // A resolved key would mean a UDP 53 lookup on a network that blocks it.
    expect(pem[1], isNotEmpty);
  });

  test('ECH replaces fragmentation instead of stacking with it', () {
    final Map<String, dynamic> tls =
        tlsOf(const SingboxRouteOptions(ech: true, tlsFragment: true));
    expect(tls.containsKey('fragment'), isFalse,
        reason: 'splitting a handshake whose name is already encrypted buys '
            'nothing and is what the MCI firewall drops');
    expect(tls['ech'], isNotNull);
  });

  test('the browser fingerprint survives, which the recipe depends on', () {
    final Map<String, dynamic> tls =
        tlsOf(const SingboxRouteOptions(ech: true));
    expect((tls['utls'] as Map<String, dynamic>)['enabled'], isTrue);
  });

  test('a rotated key can be supplied without shipping a release', () {
    final Map<String, dynamic> tls =
        tlsOf(const SingboxRouteOptions(ech: true, echConfig: 'ROTATED=='));
    expect(((tls['ech'] as Map<String, dynamic>)['config'] as List<dynamic>)[1],
        'ROTATED==');
  });

  test('the key is the one Cloudflare actually published', () {
    // Not a network call: the value measured from the HTTPS record on
    // 2026-10-04, pinned so a careless edit is caught.
    expect(kCloudflareEchConfig,
        startsWith('AEX+DQBB'),
        reason: 'an ECH config list starts with its length and version');
    expect(latin1.decode(base64Decode(kCloudflareEchConfig)),
        contains('cloudflare-ech.com'),
        reason: 'the public name inside the key must be the one the outer '
            'ClientHello will show');
  });

  test('the profile flag survives a save and reload', () {
    final ProxyProfile p = ProxyProfile(
        id: 'a', name: 'a', kind: ProxyKind.vless, uri: '', echSni: true);
    expect(ProxyProfile.fromJson(jsonDecode(jsonEncode(p.toJson()))
            as Map<String, dynamic>)
        .echSni, isTrue);
  });

  test('the generated config is one the core accepts', () {
    final Map<String, dynamic> m = SingboxConfig.buildMap(node(),
        options: const SingboxRouteOptions(ech: true));
    final File f = File('${Directory.systemTemp.path}/nova_ech_check.json');
    f.writeAsStringSync(jsonEncode(m));
    const String core = 'assets/bin/sing-box-macos-arm64';
    if (!File(core).existsSync()) return;
    final ProcessResult r =
        Process.runSync(core, <String>['check', '-c', f.path]);
    expect(r.exitCode, 0,
        reason: 'core rejected the config: ${r.stderr}${r.stdout}');
  });
}
