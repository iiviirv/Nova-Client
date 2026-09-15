import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// The app's own WireGuard flow, not the raw core calls.
///
/// A probe driving the core directly found nothing wrong with WireGuard: it
/// scanned, verified and carried traffic in twenty seconds. The tester's WireGuard
/// still will not pass traffic. So the fault is in what the app does around
/// those calls, and the most obvious difference is that the app runs a search
/// (which opens a verification tunnel of its own) and then immediately opens
/// the real tunnel. If the verification's tunnel is still holding the WARP
/// session, the real one has nothing left to take.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => AetherTunnel.stop());

  Future<String> throughSocks(int port) async {
    final Socket s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 10));
    final StreamIterator<List<int>> it = StreamIterator<List<int>>(s);
    Future<List<int>> next() async {
      if (!await it.moveNext()) throw StateError('proxy closed');
      return it.current;
    }
    s.add(<int>[0x05, 0x01, 0x00]);
    await next();
    final List<int> n = utf8.encode('api.ipify.org');
    s.add(<int>[0x05, 0x01, 0x00, 0x03, n.length, ...n, 0x00, 0x50]);
    final List<int> r = await next();
    if (r.length < 2 || r[1] != 0x00) {
      s.destroy();
      throw StateError('CONNECT refused: $r');
    }
    s.add(utf8.encode('GET / HTTP/1.1\r\nHost: api.ipify.org\r\n'
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

  testWidgets('search then connect, the way the app does it',
      (WidgetTester tester) async {
    final Directory support = await getApplicationSupportDirectory();
    const AetherOptions wg = AetherOptions(mode: AetherMode.wg);

    final AetherCoreSearch search = AetherCoreSearch();
    final AetherFindResult found = await search.run(wg, (p) {
      // ignore: avoid_print
      print('WGAPP_PROGRESS attempt=${p.attempt} verifying=${p.verifying} '
          'ruledOut=${p.ruledOut}');
    });
    // ignore: avoid_print
    print('WGAPP_SEARCH ok=${found.ok} endpoint=${found.endpoint} '
        'attempts=${found.attempts} err=${found.error}');
    expect(found.ok, isTrue, reason: 'search: ${found.error}');

    // Straight into the real tunnel, with no pause, which is what the dashboard
    // shortcut does.
    final AetherTunnel t = await AetherTunnel.start(wg,
        endpoint: found.endpoint!, identityBase: '${support.path}/aether');
    // ignore: avoid_print
    print('WGAPP_TUNNEL socks=${t.socksPort}');

    try {
      final String body = await throughSocks(t.socksPort);
      // ignore: avoid_print
      print('WGAPP_EXIT=${body.split("\r\n\r\n").last.trim()}');
      expect(body, contains('200 OK'));
    } catch (e) {
      // ignore: avoid_print
      print('WGAPP_NO_TRAFFIC=$e');
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
