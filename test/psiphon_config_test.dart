import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';

/// The shape the tester in Iran asked for: Psiphon dialling out through a
/// running Aether tunnel, so WARP carries the bytes at speed while Psiphon
/// decides where they surface. WARP alone lands on an Iranian-looking address
/// and sanctioned services refuse it; Psiphon alone is slow or blocked when
/// dialled from inside.
void main() {
  _carrierModel();
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

  group('how a profile stores it', () {
    test('the mode round-trips', () {
      for (final PsiphonMode m in PsiphonMode.values) {
        expect(PsiphonConfig.modeFromLink(PsiphonConfig.linkFor(m)), m);
      }
    });

    test('a link from another scheme is not ours', () {
      expect(PsiphonConfig.modeFromLink('vless://x@h:443'), isNull);
      expect(PsiphonConfig.modeFromLink('not a link'), isNull);
    });

    test('an unrecognised mode opens as direct rather than refusing', () {
      expect(PsiphonConfig.modeFromLink('psiphon://somethingelse'),
          PsiphonMode.direct,
          reason: 'a profile that will not open at all is worse than one that '
              'opens in the mode that works without a tunnel already running');
    });

    test('no port is written into the stored link', () {
      // A saved port is a profile that breaks when that port is taken.
      expect(PsiphonConfig.linkFor(PsiphonMode.throughAether),
          isNot(contains('1081')));
    });
  });

  group('the Aether config a chained profile rides on', () {
    const String aether = 'aether://188.114.97.3:2408?protocol=wg&scan=balanced';

    test('travels inside the link, so the profile is self-contained', () {
      final String link =
          PsiphonConfig.linkFor(PsiphonMode.throughAether, viaLink: aether);
      expect(PsiphonConfig.modeFromLink(link), PsiphonMode.throughAether);
      expect(PsiphonConfig.viaLinkFrom(link), aether,
          reason: 'Nova has one active profile, so the tunnel this rides on '
              'cannot be a separate connection the user made; this profile '
              'has to know which gateway to bring up');
    });

    test('survives the query characters an aether link contains', () {
      final String link =
          PsiphonConfig.linkFor(PsiphonMode.throughAether, viaLink: aether);
      expect(link, contains('%'), reason: 'the inner link must be encoded');
      expect(PsiphonConfig.viaLinkFrom(link), contains('protocol=wg'));
      expect(PsiphonConfig.viaLinkFrom(link), contains('scan=balanced'));
    });

    test('direct mode carries none', () {
      expect(
          PsiphonConfig.viaLinkFrom(
              PsiphonConfig.linkFor(PsiphonMode.direct, viaLink: aether)),
          isNull);
    });

    test('a chained link with no config is readable but carries nothing', () {
      expect(PsiphonConfig.modeFromLink('psiphon://aether'),
          PsiphonMode.throughAether);
      expect(PsiphonConfig.viaLinkFrom('psiphon://aether'), isNull);
    });

    /// Chaining over any config, not only WARP, asked for 2026-10-10. Google
    /// refuses requests from a Cloudflare address, so Gemini says "not
    /// available in your region" through a Worker config however well it
    /// carries everything else; Psiphon's exit is not a Cloudflare address.
    group('riding on a config that is not WARP', () {
      const String node =
          'vless://00000000-0000-0000-0000-000000000000@edge.example.com:443'
          '?security=tls&type=ws&path=/&sni=edge.example.com#carrier';

      test('the two chained kinds are told apart by the link, not guessed', () {
        final String warp = PsiphonConfig.linkFor(PsiphonMode.throughAether,
            viaLink: 'aether://1.2.3.4:443?protocol=masque');
        final String other =
            PsiphonConfig.linkFor(PsiphonMode.throughCarrier, viaLink: node);
        expect(PsiphonConfig.modeFromLink(warp), PsiphonMode.throughAether);
        expect(PsiphonConfig.modeFromLink(other), PsiphonMode.throughCarrier);
        expect(warp, isNot(other));
      });

      test('the carrier survives a round trip, query characters and all', () {
        final String link =
            PsiphonConfig.linkFor(PsiphonMode.throughCarrier, viaLink: node);
        expect(PsiphonConfig.viaLinkFrom(link), node,
            reason: 'the profile has to be self-contained: Nova has one active '
                'profile, so the carrier cannot be a connection made '
                'separately');
      });

      test('both chained kinds need an upstream port, and say so', () {
        for (final PsiphonMode m in <PsiphonMode>[
          PsiphonMode.throughAether,
          PsiphonMode.throughCarrier,
        ]) {
          expect(psiphonIsChained(m), isTrue, reason: m.name);
          expect(
              PsiphonConfig(socksPort: 1080, dataDir: '/tmp/p', mode: m)
                  .problem,
              isNotNull,
              reason: 'a chained config with no upstream would dial direct, '
                  'which is the one outcome the user did not ask for');
        }
      });

      test('both chained kinds drop the QUIC protocols', () {
        // A SOCKS5 upstream carries TCP. A QUIC protocol would dial, fail, and
        // burn an attempt a working one could have used.
        for (final PsiphonMode m in <PsiphonMode>[
          PsiphonMode.throughAether,
          PsiphonMode.throughCarrier,
        ]) {
          final List<Object?> protos = PsiphonConfig(
                  socksPort: 1080,
                  dataDir: '/tmp/p',
                  mode: m,
                  upstreamSocksPort: 1081)
              .engineJson()['LimitTunnelProtocols']! as List<Object?>;
          expect(protos.any((Object? p) => '$p'.contains('QUIC')), isFalse,
              reason: m.name);
        }
      });

      test('an older build reads a carrier link as direct, not as broken', () {
        // modeFromLink falls back to direct for a host it does not know, which
        // is what a build from before this feature does with one of these
        // links. Opening in the safer mode beats refusing to open.
        expect(PsiphonConfig.modeFromLink('psiphon://somethingnew?via=x'),
            PsiphonMode.direct);
      });
    });
  });
}

/// Field report from Iran, build 166: creating a Psiphon through WARP profile
/// and tapping Connect gave "this Psiphon profile is set to run through WARP
/// but has no WARP config saved", on a device where all three built-in WARP
/// profiles connect fine. Requiring the user to nominate one was the wrong
/// model. Psiphon does not reach its network from inside Iran unaided, so a
/// chained profile has to work out of the box.
void _carrierModel() {
  group('a chained profile does not require a saved WARP config', () {
    test('a link with no config is still a valid chained profile', () {
      const String link = 'psiphon://aether';
      expect(PsiphonConfig.modeFromLink(link), PsiphonMode.throughAether,
          reason: 'this is what the editor writes, and it must remain usable');
      expect(PsiphonConfig.viaLinkFrom(link), isNull,
          reason: 'the controller supplies the carrier, not the profile');
    });

    test('a saved config still wins when one is present', () {
      const String aether = 'aether://188.114.97.3:2408?protocol=wg';
      final String link =
          PsiphonConfig.linkFor(PsiphonMode.throughAether, viaLink: aether);
      expect(PsiphonConfig.viaLinkFrom(link), aether);
    });
  });
}
