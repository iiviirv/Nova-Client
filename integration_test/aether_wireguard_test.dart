import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';

/// Why WireGuard connects and carries nothing, when MASQUE and gool are fine.
///
/// Reported after build 144: a WireGuard config is created, connects, and sits
/// on verifying. It worked in 143. Printing every step of the one protocol that
/// broke is cheaper than reasoning about which of three commits did it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => AetherTunnel.stop());

  Future<String> throughSocks(int port, String host, String path) async {
    final Socket s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 10));
    final StreamIterator<List<int>> it = StreamIterator<List<int>>(s);
    Future<List<int>> next() async {
      if (!await it.moveNext()) throw StateError('proxy closed');
      return it.current;
    }
    s.add(<int>[0x05, 0x01, 0x00]);
    final List<int> hello = await next();
    if (hello.length < 2 || hello[1] != 0x00) {
      s.destroy();
      throw StateError('greeting refused: $hello');
    }
    final List<int> name = utf8.encode(host);
    s.add(<int>[0x05, 0x01, 0x00, 0x03, name.length, ...name, 0x00, 0x50]);
    final List<int> reply = await next();
    if (reply.length < 2 || reply[1] != 0x00) {
      s.destroy();
      throw StateError('CONNECT refused: $reply');
    }
    s.add(utf8.encode('GET $path HTTP/1.1\r\nHost: $host\r\n'
        'Connection: close\r\n\r\n'));
    final StringBuffer b = StringBuffer();
    try {
      while (await it.moveNext()) {
        b.write(utf8.decode(it.current, allowMalformed: true));
      }
    } finally {
      s.destroy();
    }
    return b.toString();
  }

  testWidgets('every step of a WireGuard config, printed',
      (WidgetTester tester) async {
    final Directory support = await getApplicationSupportDirectory();
    final String base = '${support.path}/aether';
    const AetherOptions wg =
        AetherOptions(mode: AetherMode.wg, scan: AetherScan.turbo);
    final AetherCore core = AetherCore.open();

    // What we actually send, which is the thing that changed.
    // ignore: avoid_print
    print('WG_IDENTITY_PAYLOAD=${AetherPayloads.identity(wg, base: base)}');
    // ignore: avoid_print
    print('WG_SCAN_PAYLOAD=${AetherPayloads.scan(wg)}');
    // ignore: avoid_print
    print('WG_TUNNEL_PAYLOAD='
        '${AetherPayloads.tunnel(wg, endpoint: "1.2.3.4:2408", socks: "127.0.0.1:1")}');

    final AetherReply open = core.identityOpen(wg, base: base);
    AetherJobStatus st = core.jobPoll((open['job'] as num).toInt());
    for (int i = 0; i < 90 && st.isRunning; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      st = core.jobPoll((open['job'] as num).toInt());
    }
    // ignore: avoid_print
    print('WG_IDENTITY state=${st.state} result=${st.result} err=${st.error}');
    expect(st.state, AetherJobState.done, reason: 'identity: ${st.error}');
    final int id = (st.result![kAetherIdentityField] as num).toInt();

    Future<AetherJobStatus> run(AetherReply started, {int mins = 4}) async {
      if (!started.ok) {
        return AetherJobStatus(AetherJobState.failed, error: started.error);
      }
      final int job = (started['job'] as num).toInt();
      AetherJobStatus s = core.jobPoll(job);
      final DateTime end = DateTime.now().add(Duration(minutes: mins));
      while (s.isRunning && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        s = core.jobPoll(job);
      }
      return s;
    }

    final AetherJobStatus scan = await run(core.scanStart(id, wg));
    // ignore: avoid_print
    print('WG_SCAN state=${scan.state} result=${scan.result} err=${scan.error}');
    final String? endpoint = AetherEndpoint.parse(scan.result?['endpoint']);
    // ignore: avoid_print
    print('WG_ENDPOINT=$endpoint');
    expect(endpoint, isNotNull, reason: 'wg scan found nothing');

    final int vp = await AetherTunnel.freeLoopbackPort();
    final AetherJobStatus ver = await run(
        core.verifyStart(id, wg, endpoint: endpoint!, socks: '127.0.0.1:$vp'));
    // ignore: avoid_print
    print('WG_VERIFY state=${ver.state} result=${ver.result} err=${ver.error}');

    // The real tunnel, exactly as connect starts it.
    try {
      final AetherTunnel t =
          await AetherTunnel.start(wg, endpoint: endpoint, identityBase: base);
      // ignore: avoid_print
      print('WG_TUNNEL_UP socks=${t.socksPort}');
      final String body = await throughSocks(t.socksPort, 'api.ipify.org', '/');
      // ignore: avoid_print
      print('WG_EXIT=${body.split("\r\n\r\n").last.trim()}');
      expect(body, contains('200 OK'));
    } catch (e) {
      // ignore: avoid_print
      print('WG_TUNNEL_FAILED=$e');
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
