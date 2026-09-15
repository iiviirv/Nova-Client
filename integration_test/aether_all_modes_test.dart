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

/// All three modes, through the app's own path, carrying real traffic.
///
/// gool is the one that needs this. It was silently running as MASQUE, because
/// the core turns any transport it does not recognise into Masque and the
/// tunnel payload had stopped carrying the mode. It worked, which is how it
/// passed a tester's check. Restoring the mode makes it genuinely gool for the
/// first time, so "it used to work" says nothing about whether it still does.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => AetherTunnel.stop());

  Future<String> exitIp(int port) async {
    final Socket s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 12));
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
    return b.toString().split('\r\n\r\n').last.trim();
  }

  for (final AetherMode mode in AetherMode.values) {
    testWidgets('${mode.name} finds a gateway and carries traffic',
        (WidgetTester tester) async {
      final Directory support = await getApplicationSupportDirectory();
      final AetherOptions o = AetherOptions(mode: mode);

      final AetherFindResult found =
          await AetherCoreSearch().run(o, (_) {});
      // ignore: avoid_print
      print('MODE_${mode.name}_SEARCH ok=${found.ok} '
          'endpoint=${found.endpoint} attempts=${found.attempts} '
          'err=${found.error}');
      expect(found.ok, isTrue, reason: '${mode.name} search: ${found.error}');

      final AetherTunnel t = await AetherTunnel.start(o,
          endpoint: found.endpoint!, identityBase: '${support.path}/aether');
      final String ip = await exitIp(t.socksPort);
      // ignore: avoid_print
      print('MODE_${mode.name}_EXIT=$ip via ${found.endpoint}');
      expect(RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip), isTrue,
          reason: '${mode.name} tunnel carried nothing usable: "$ip"');
      await AetherTunnel.stop();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
