import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';

/// The whole chain, once: find a gateway, open a tunnel to it, and carry a real
/// request through it.
///
/// Every part of this is tested on its own. None of that proves the parts fit
/// together, and the seams are where this kind of feature fails: a tunnel that
/// reports itself up before the port answers, a verification that proves an
/// address other than the one saved, a payload the core refuses. This is the
/// first run of the actual sequence a user triggers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Fetches a URL through a SOCKS5 proxy, by hand.
  ///
  /// Dart's HttpClient cannot use a SOCKS proxy, and the point here is to prove
  /// bytes move through the tunnel rather than to be elegant about it.
  Future<String> throughSocks(int port, String host, String path) async {
    final Socket s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 10));
    final StreamIterator<List<int>> it = StreamIterator<List<int>>(s);
    Future<List<int>> next() async {
      if (!await it.moveNext()) throw StateError('the proxy closed the socket');
      return it.current;
    }

    // Greeting: SOCKS5, one method, no authentication.
    s.add(<int>[0x05, 0x01, 0x00]);
    final List<int> hello = await next();
    if (hello.length < 2 || hello[0] != 0x05 || hello[1] != 0x00) {
      s.destroy();
      throw StateError('the proxy refused the greeting: $hello');
    }

    // CONNECT to a domain on port 80, resolved inside the tunnel.
    final List<int> name = utf8.encode(host);
    s.add(<int>[0x05, 0x01, 0x00, 0x03, name.length, ...name, 0x00, 0x50]);
    final List<int> reply = await next();
    if (reply.length < 2 || reply[1] != 0x00) {
      s.destroy();
      throw StateError('the proxy refused CONNECT: $reply');
    }

    s.add(utf8.encode('GET $path HTTP/1.1\r\nHost: $host\r\n'
        'Connection: close\r\n\r\n'));
    final StringBuffer body = StringBuffer();
    try {
      while (await it.moveNext()) {
        body.write(utf8.decode(it.current, allowMalformed: true));
      }
    } finally {
      s.destroy();
    }
    return body.toString();
  }

  tearDown(() async => AetherTunnel.stop());

  test('a gateway is found, a tunnel opens, and traffic goes through it',
      () async {
    expect(AetherCore.available, isTrue, reason: 'no core to test with');
    final Directory support = await getApplicationSupportDirectory();
    final String base = '${support.path}/aether';
    const AetherOptions options = AetherOptions(scan: AetherScan.turbo);
    final AetherCore core = AetherCore.open();

    // 1. Identity.
    final AetherReply openReply = core.identityOpen(options, base: base);
    expect(openReply.ok, isTrue, reason: 'identity: ${openReply.error}');
    AetherJobStatus st = core.jobPoll((openReply['job'] as num).toInt());
    for (int i = 0; i < 90 && st.isRunning; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      st = core.jobPoll((openReply['job'] as num).toInt());
    }
    expect(st.state, AetherJobState.done, reason: 'identity: ${st.error}');
    final int identity = (st.result![kAetherIdentityField] as num).toInt();

    // 2. Search, with the automatic retry that is the point of the feature.
    Future<AetherJobStatus> await_(AetherReply started) async {
      if (!started.ok) {
        return AetherJobStatus(AetherJobState.failed, error: started.error);
      }
      final int job = (started['job'] as num).toInt();
      AetherJobStatus s = core.jobPoll(job);
      final DateTime end = DateTime.now().add(const Duration(minutes: 3));
      while (s.isRunning && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        s = core.jobPoll(job);
      }
      return s;
    }

    final AetherGatewayFinder finder = AetherGatewayFinder(
      attempts: 3,
      scan: (AetherOptions o, List<String> excluded) =>
          await_(core.scanStart(identity, o, excluded: excluded)),
      verify: (AetherOptions o, String endpoint) async {
        final int p = await AetherTunnel.freeLoopbackPort();
        return await_(core.verifyStart(identity, o,
            endpoint: endpoint, socks: '127.0.0.1:$p'));
      },
    );
    final AetherFindResult found = await finder.find(options);
    // ignore: avoid_print
    print('AETHER_E2E_SEARCH ok=${found.ok} endpoint=${found.endpoint} '
        'attempts=${found.attempts} ruledOut=${found.rejected} '
        'error=${found.error}');
    expect(found.ok, isTrue, reason: 'no gateway carried traffic: ${found.error}');

    // 3. The tunnel a connect would start.
    final AetherTunnel tunnel = await AetherTunnel.start(options,
        endpoint: found.endpoint!, identityBase: base);
    // ignore: avoid_print
    print('AETHER_E2E_TUNNEL socks=${tunnel.socksPort} via ${found.endpoint}');

    // 4. Real traffic, and an exit address that is not this device's.
    final String body =
        await throughSocks(tunnel.socksPort, 'api.ipify.org', '/');
    final String exit = body.split('\r\n\r\n').last.trim();
    // ignore: avoid_print
    print('AETHER_E2E_EXIT_IP=$exit');
    expect(body, contains('200 OK'), reason: 'no HTTP response came back');
    expect(RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(exit), isTrue,
        reason: 'expected an exit address, got: $exit');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
