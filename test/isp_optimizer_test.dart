import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/isp_optimizer.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

ProxyNode _vlessNode({String? fingerprint}) => ProxyNode(
      protocol: NodeProtocol.vless,
      server: 'nova.example.com',
      port: 443,
      uuid: 'b9c40223-bbc5-4311-89d3-f1ed54bbca86',
      tls: true,
      sni: 'nova.example.com',
      network: 'ws',
      wsPath: '/nova',
      wsHost: 'nova.example.com',
      fingerprint: fingerprint,
      tag: 'Nova',
    );

Map<String, dynamic> _firstTls(String config) {
  final Map<String, dynamic> doc = jsonDecode(config) as Map<String, dynamic>;
  final List<dynamic> outs = doc['outbounds'] as List<dynamic>;
  final Map<String, dynamic> proxy = outs.cast<Map<String, dynamic>>().firstWhere(
        (Map<String, dynamic> o) => (o['tls'] is Map),
      );
  return proxy['tls'] as Map<String, dynamic>;
}

void main() {
  group('SingboxConfig fingerprintOverride', () {
    test('override wins over the node fingerprint and the chrome default', () {
      final String cfg = SingboxConfig.build(
        _vlessNode(fingerprint: 'safari'),
        options: const SingboxRouteOptions(fingerprintOverride: 'firefox'),
      );
      final Map<String, dynamic> tls = _firstTls(cfg);
      expect((tls['utls'] as Map)['fingerprint'], 'firefox');
    });

    test('empty override keeps the node fingerprint', () {
      final String cfg = SingboxConfig.build(
        _vlessNode(fingerprint: 'safari'),
        options: const SingboxRouteOptions(fingerprintOverride: ''),
      );
      expect((_firstTls(cfg)['utls'] as Map)['fingerprint'], 'safari');
    });

    test('no override, no node fingerprint falls back to chrome', () {
      final String cfg = SingboxConfig.build(
        _vlessNode(),
        options: const SingboxRouteOptions(),
      );
      expect((_firstTls(cfg)['utls'] as Map)['fingerprint'], 'chrome');
    });

    test('tlsFragment=false drops the fragment keys', () {
      final String cfg = SingboxConfig.build(
        _vlessNode(),
        options: const SingboxRouteOptions(tlsFragment: false),
      );
      expect(_firstTls(cfg).containsKey('fragment'), isFalse);
    });
  });

  group('IspProfile matching', () {
    final IspProfile profile =
        IspProfile.fromJson(kBuiltinIspProfileJson);

    IspRule? ruleFor(String code) {
      for (final IspRule r in profile.isps) {
        if (r.mccmnc.contains(code)) return r;
      }
      return null;
    }

    test('Irancell 43235 -> chrome + fragment', () {
      final IspRule? r = ruleFor('43235');
      expect(r, isNotNull);
      expect(r!.label, contains('Irancell'));
      expect(r.settings.fingerprint, 'chrome');
      expect(r.settings.tlsFragment, isTrue);
    });

    test('MCI 43211 -> randomized', () {
      expect(ruleFor('43211')?.settings.fingerprint, 'randomized');
    });

    test('Rightel 43220 -> firefox', () {
      expect(ruleFor('43220')?.settings.fingerprint, 'firefox');
    });

    test('unknown code has no mccmnc rule (falls through to default)', () {
      expect(ruleFor('310260'), isNull);
      expect(profile.defaults.fingerprint, 'chrome');
    });

    test('profile parses a server payload shape', () {
      final IspProfile p = IspProfile.fromJson(<String, dynamic>{
        'version': 2,
        'default': <String, dynamic>{'fingerprint': 'ios', 'tlsFragment': true},
        'isps': <dynamic>[
          <String, dynamic>{
            'label': 'Test',
            'mccmnc': <dynamic>['99999'],
            'settings': <String, dynamic>{'fingerprint': 'edge'},
          },
        ],
      });
      expect(p.version, 2);
      expect(p.defaults.fingerprint, 'ios');
      expect(p.isps.single.mccmnc, <String>['99999']);
      expect(p.isps.single.settings.fingerprint, 'edge');
    });
  });
}
