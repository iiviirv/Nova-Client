import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';

/// The shape the tester in Iran asked for: Psiphon dialling out through a
/// running Aether tunnel, so WARP carries the bytes at speed while Psiphon
/// decides where they surface. WARP alone lands on an Iranian-looking address
/// and sanctioned services refuse it; Psiphon alone is slow or blocked when
/// dialled from inside.
void main() {
  PsiphonConfig direct() => const PsiphonConfig(
      socksPort: 1081, dataDir: '/tmp/psi');

  PsiphonConfig chained({int upstream = 40821, int socks = 1081}) =>
      PsiphonConfig(
        socksPort: socks,
        dataDir: '/tmp/psi',
        mode: PsiphonMode.throughAether,
        upstreamSocksPort: upstream,
      );

  group('reaching Psiphon at all', () {
    test('carries the identifiers and the signed server list', () {
      final Map<String, Object?> j = direct().engineJson();
      expect(j['PropagationChannelId'], isNotEmpty);
      expect(j['SponsorId'], isNotEmpty);
      expect(j['RemoteServerListSignaturePublicKey'], isNotEmpty);
      // The URL travels base64 inside the object, not as a plain string.
      final list = j['RemoteServerListURLs'] as List<dynamic>;
      final String encoded = (list.single as Map<String, String>)['URL']!;
      expect(utf8.decode(base64.decode(encoded)),
          startsWith('https://'),
          reason: 'Psiphon decodes this; a plain URL here reaches nothing');
    });

    test('serves SOCKS where sing-box will look, and opens no second listener',
        () {
      expect(direct().engineJson()['LocalSocksProxyPort'], 1081);
      expect(direct().engineJson()['LocalHttpProxyPort'], 0);
    });

    test('never volunteers the user as a relay for other people', () {
      final Map<String, Object?> j = direct().engineJson();
      expect(j['InproxyTunnelProtocolPreferProbability'], 0.0);
      expect(j['InproxyTunnelProtocolSelectionProbability'], 0.0);
    });
  });

  group('through Aether', () {
    test('dials out through the tunnel rather than the open network', () {
      expect(chained().engineJson()['UpstreamProxyURL'],
          'socks5://127.0.0.1:40821');
    });

    test('direct mode leaves the upstream out entirely', () {
      expect(direct().engineJson().containsKey('UpstreamProxyURL'), isFalse);
    });

    test('drops every QUIC protocol, because a SOCKS upstream carries TCP', () {
      final protocols =
          chained().engineJson()['LimitTunnelProtocols'] as List<String>;
      expect(protocols, isNotEmpty);
      expect(protocols.where((String p) => p.contains('QUIC')), isEmpty,
          reason: 'QUIC is UDP and cannot cross a SOCKS5 proxy, so offering it '
              'burns attempts that a working protocol could have used');
      expect(protocols, contains('OSSH'));
    });

    test('direct mode keeps QUIC, where it works', () {
      final protocols =
          direct().engineJson()['LimitTunnelProtocols'] as List<String>;
      expect(protocols.where((String p) => p.contains('QUIC')), isNotEmpty);
    });
  });

  group('configurations that would fail quietly', () {
    test('a chained config with no upstream port is refused', () {
      const PsiphonConfig c = PsiphonConfig(
          socksPort: 1081,
          dataDir: '/tmp/psi',
          mode: PsiphonMode.throughAether);
      expect(c.problem, isNotNull,
          reason: 'silently dialling direct gives the user the Iranian exit '
              'and the sanctions blocks they were trying to escape');
    });

    test('Psiphon cannot be told to use its own port as its way out', () {
      expect(chained(upstream: 1081, socks: 1081).problem, isNotNull);
    });

    test('a usable config has nothing to report', () {
      expect(direct().problem, isNull);
      expect(chained().problem, isNull);
    });

    test('a port outside the range is refused', () {
      expect(const PsiphonConfig(socksPort: 0, dataDir: '/tmp/p').problem,
          isNotNull);
      expect(const PsiphonConfig(socksPort: 70000, dataDir: '/tmp/p').problem,
          isNotNull);
    });

    test('nowhere to keep its state is refused', () {
      expect(const PsiphonConfig(socksPort: 1081, dataDir: '  ').problem,
          isNotNull);
    });
  });
}
