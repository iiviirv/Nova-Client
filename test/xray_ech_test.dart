import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/xray/xray_config.dart';

/// Reported from the field: xhttp servers ignored the ECH switch. They run on
/// the Xray core, and the ECH work had gone into the sing-box config only, so
/// the switch read on and nothing was hidden.
///
/// Measured against the shipped Xray 26.3.27, because the two cores do not take
/// the same thing and guessing would have shipped a field that does nothing:
///   - `echConfigList` takes only the `domain+resolver` query form. A literal
///     base64 key produces no ECH activity at all, so Nova cannot hand Xray the
///     key it already fetched for sing-box.
///   - Xray resolves it itself over `udp://` or `https://`. A `tcp://` resolver
///     produces no ECH activity either, which would turn ECH off for xhttp
///     while the switch still read on.
void main() {
  ProxyNode xhttp({bool reality = false}) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: '104.16.0.1',
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
        tls: true,
        sni: 'example.com',
        network: 'xhttp',
        wsPath: '/x',
        realityPublicKey: reality ? 'Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMDA' : null,
        tag: 'n',
      );

  Map<String, dynamic> tlsOf(Map<String, dynamic> cfg) {
    final List<dynamic> outs = cfg['outbounds'] as List<dynamic>;
    final Map<String, dynamic> o = outs.first as Map<String, dynamic>;
    final Map<String, dynamic> stream =
        o['streamSettings'] as Map<String, dynamic>;
    return (stream['tlsSettings'] ?? stream['realitySettings'])
        as Map<String, dynamic>;
  }

  test('without ECH the config is unchanged', () {
    expect(tlsOf(XrayConfig.buildMap(xhttp())).containsKey('echConfigList'),
        isFalse);
  });

  test('with ECH the lookup is passed, in the only form Xray takes', () {
    final Map<String, dynamic> tls =
        tlsOf(XrayConfig.buildMap(xhttp(), ech: EchSpec.fallback.xrayText));
    expect(tls['echConfigList'], EchSpec.fallback.xrayText);
    expect(tls['echConfigList'], contains('+'),
        reason: 'Xray takes the domain+resolver form; a bare key does nothing');
    expect(tls['echConfigList'], isNot(startsWith('AEX')),
        reason: 'a literal key produced no ECH activity at all when measured');
  });

  test('a custom lookup reaches the core as written', () {
    final EchSpec s = EchSpec.parse('my.example+udp://9.9.9.9');
    expect(tlsOf(XrayConfig.buildMap(xhttp(), ech: s.xrayText))['echConfigList'],
        'my.example+udp://9.9.9.9');
  });

  test('a tcp resolver is swapped, because Xray cannot use one', () {
    final EchSpec s = EchSpec.parse('my.example+tcp://9.9.9.9');
    expect(s.xrayResolverChanged, isTrue);
    expect(s.xrayText, 'my.example+${EchSpec.fallback.resolver}',
        reason: 'leaving tcp would read as ECH on while doing nothing at all');
    // The sing-box side still honours exactly what was asked for.
    expect(s.resolver, 'tcp://9.9.9.9');
  });

  test('udp and DoH resolvers pass through untouched', () {
    for (final String r in <String>['udp://1.1.1.1', 'https://1.1.1.1/dns-query']) {
      final EchSpec s = EchSpec.parse('a.com+$r');
      expect(s.xrayResolverChanged, isFalse);
      expect(s.xrayText, 'a.com+$r');
    }
  });

  test('the core accepts a config carrying it', () {
    const String bin = 'assets/bin/xray-macos-arm64';
    if (!File(bin).existsSync()) return;
    final File f = File('${Directory.systemTemp.path}/nova_xray_ech.json');
    f.writeAsStringSync(
        XrayConfig.build(xhttp(), ech: EchSpec.fallback.xrayText));
    final ProcessResult r = Process.runSync(bin, <String>['run', '-test', '-c', f.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}');
  });

  group('which profiles get it', () {
    ProxyProfile p({bool ech = false, String? lookup}) => ProxyProfile(
          id: 'x',
          name: 'x',
          kind: ProxyKind.subscription,
          uri: 'https://example.com/sub',
          echSni: ech,
          echConfigList: lookup,
        );

    test('a profile with ECH off gets nothing', () {
      expect(xrayEchFor(p()), isNull,
          reason: 'emitting it anyway would turn ECH on for xhttp servers in '
              'a profile whose switch is off');
      expect(xrayEchFor(null), isNull);
    });

    test('a profile with ECH on gets the default lookup', () {
      expect(xrayEchFor(p(ech: true)), EchSpec.fallback.xrayText);
    });

    test('and an edited one gets what was edited', () {
      expect(xrayEchFor(p(ech: true, lookup: 'a.com+udp://9.9.9.9')),
          'a.com+udp://9.9.9.9');
    });
  });

  test('every Xray config Nova builds carries the lookup', () {
    // Structural, and counted rather than merely present: the gap that made
    // this a bug was one call site out of several, so "contains" would pass
    // while an xhttp profile silently had no ECH.
    for (final String path in <String>[
      'lib/src/core/proxy/singbox_proxy_controller.dart',
      'lib/src/core/proxy/desktop_proxy_controller.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      final int builds = RegExp(r'XrayConfig\.build(Multi)?\(').allMatches(src).length;
      final int withEch = 'ech: xrayEchFor('.allMatches(src).length;
      expect(withEch, builds,
          reason: '$path builds $builds Xray configs but passes the ECH lookup '
              'to $withEch of them; the missing one is how xhttp came to '
              'ignore the switch');
    }
  });
}
