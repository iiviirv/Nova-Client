import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/measure_runner.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';

/// Making the server test stop spending its time on servers that are already
/// gone.
///
/// A tester in Iran filmed a 12-server subscription taking most of a minute to
/// test, with one server (a filtered Finland address) that could never answer.
/// It was not slow because the network was slow. Every node, dead or alive, was
/// given the long first-dial budget meant for protocols that build a session,
/// then a retry of it, then a place in the late retry pass. A filtered address
/// spent about thirty seconds and one of only eight slots proving what a
/// refused TCP handshake says in under a second.
void main() {
  group('a refused TCP connection ends the question early', () {
    test('a port nothing is listening on is reported unreachable', () async {
      // Bind and release, so the port is real, local, and certain to be closed.
      final ServerSocket s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = s.port;
      await s.close();

      final Set<String> dead = await MeasureRunner.unreachableTags(
        <String, ({String host, int port})>{
          'node-0': (host: '127.0.0.1', port: deadPort),
        },
        timeout: const Duration(seconds: 2),
      );
      expect(dead, contains('node-0'),
          reason: 'a server that refuses TCP cannot carry a proxy over it');
    });

    test('a port that accepts is NOT written off', () async {
      final ServerSocket s =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => s.close());
      s.listen((Socket c) => c.destroy());

      final Set<String> dead = await MeasureRunner.unreachableTags(
        <String, ({String host, int port})>{
          'node-0': (host: '127.0.0.1', port: s.port),
        },
        timeout: const Duration(seconds: 2),
      );
      expect(dead, isEmpty,
          reason: 'accepting TCP proves nothing about the proxy on top of it, '
              'so the real dial must still decide');
    });

    test('an empty probe map does nothing', () async {
      expect(
          await MeasureRunner.unreachableTags(
              const <String, ({String host, int port})>{}),
          isEmpty);
    });
  });

  group('a failure is asked twice before it is believed', () {
    test('a port that answers on the second ask is not written off', () async {
      // A lost SYN is not a dead server. SYN retransmission is about a second,
      // so on a lossy path out of Iran one dropped packet used to delete a
      // working server from the run AND from the late retry pass.
      //
      // Simulated by closing the port for the first ask and binding it for the
      // second, which is what a retransmitted handshake looks like from here.
      final ServerSocket first =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = first.port;
      await first.close();

      final Map<String, ({String host, int port})> probes =
          <String, ({String host, int port})>{
        'node-0': (host: '127.0.0.1', port: port),
      };
      final Set<String> pass1 = await MeasureRunner.unreachableTags(probes,
          timeout: const Duration(seconds: 1));
      expect(pass1, contains('node-0'), reason: 'the first ask finds nothing');

      // Now the server is there, as a retransmit would have found it.
      final ServerSocket second = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, port);
      addTearDown(() async => second.close());
      second.listen((Socket c) => c.destroy());

      final Set<String> pass2 = await MeasureRunner.unreachableTags(probes,
          timeout: const Duration(seconds: 1));
      expect(pass2, isEmpty,
          reason: 'the second ask is what saves a live server from one lost '
              'packet');
    });
  });

  group('only the protocols that need it get the long first dial', () {
    ProxyNode n(NodeProtocol p, {String? method, String? reality}) => ProxyNode(
          protocol: p,
          server: 'example.com',
          port: 443,
          method: method,
          realityPublicKey: reality,
        );

    test('session-building protocols do', () {
      // Each of these dials a bare VPS and sets up a session before it can
      // answer at all, which is what the long budget was added for.
      expect(n(NodeProtocol.hysteria2).needsSlowFirstDial, isTrue);
      expect(n(NodeProtocol.tuic).needsSlowFirstDial, isTrue);
      expect(n(NodeProtocol.mieru).needsSlowFirstDial, isTrue);
      expect(n(NodeProtocol.vless, reality: 'abc123').needsSlowFirstDial, isTrue,
          reason: 'Reality is a VLESS node carrying an x25519 key');
      expect(
          n(NodeProtocol.shadowsocks, method: '2022-blake3-aes-128-gcm')
              .needsSlowFirstDial,
          isTrue);
    });

    test('CDN-fronted protocols do not', () {
      // These ride a CDN edge and are up in a couple of hundred milliseconds,
      // so seconds two through fifteen buy nothing but waiting.
      expect(n(NodeProtocol.vless).needsSlowFirstDial, isFalse);
      expect(n(NodeProtocol.trojan).needsSlowFirstDial, isFalse);
      expect(n(NodeProtocol.naive).needsSlowFirstDial, isFalse);
      expect(
          n(NodeProtocol.shadowsocks, method: 'aes-256-gcm').needsSlowFirstDial,
          isFalse,
          reason: 'only the 2022 methods derive a session key first');
    });
  });

  group('TCP liveness is only asked of protocols it can answer for', () {
    test('UDP-native protocols are never TCP-probed', () {
      // A QUIC or WireGuard server owes nothing to a TCP SYN. Probing one would
      // call a working server dead, which is worse than the slowness this fixes.
      expect(NodeProtocol.hysteria2.tcpLivenessMeaningful, isFalse);
      expect(NodeProtocol.tuic.tcpLivenessMeaningful, isFalse);
      expect(NodeProtocol.awg.tcpLivenessMeaningful, isFalse);
    });

    test('mieru is left alone because its transport can be either', () {
      expect(NodeProtocol.mieru.tcpLivenessMeaningful, isFalse);
    });

    test('TCP-carried protocols can be asked', () {
      expect(NodeProtocol.vless.tcpLivenessMeaningful, isTrue);
      expect(NodeProtocol.trojan.tcpLivenessMeaningful, isTrue);
      expect(NodeProtocol.vmess.tcpLivenessMeaningful, isTrue);
      expect(NodeProtocol.naive.tcpLivenessMeaningful, isTrue);
    });
  });

  group('a subscription can be kept at the top of the list', () {
    ProxyProfile p({bool pinned = false}) => ProxyProfile(
          id: 'a',
          name: 'Sub A',
          kind: ProxyKind.subscription,
          uri: 'https://example.com/sub',
          pinned: pinned,
        );

    test('defaults to unpinned', () => expect(p().pinned, isFalse));

    test('survives a save and reload', () {
      final ProxyProfile back =
          ProxyProfile.fromJson(p(pinned: true).toJson());
      expect(back.pinned, isTrue,
          reason: 'a pin the user set must outlive a restart');
    });

    test('an old profile with no pinned field loads as unpinned', () {
      final Map<String, dynamic> legacy = p().toJson()..remove('pinned');
      expect(ProxyProfile.fromJson(legacy).pinned, isFalse);
    });

    test('copyWith toggles it both ways', () {
      expect(p().copyWith(pinned: true).pinned, isTrue);
      expect(p(pinned: true).copyWith(pinned: false).pinned, isFalse);
    });

    test('pinned sorts ahead, and the rest keep their order', () {
      final List<ProxyProfile> list = <ProxyProfile>[
        p().copyWith(name: 'first'),
        p(pinned: true).copyWith(name: 'pinned'),
        p().copyWith(name: 'second'),
      ];
      // The same comparator the Servers list uses.
      list.sort((ProxyProfile a, ProxyProfile b) {
        if (a.pinned == b.pinned) return 0;
        return a.pinned ? -1 : 1;
      });
      expect(list.map((ProxyProfile x) => x.name).toList(),
          <String>['pinned', 'first', 'second'],
          reason: 'a stable sort, so unpinned rows are not reshuffled');
    });
  });
}
