import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:path_provider/path_provider.dart';

/// A MasterDNS connection on a real Mac, through a real DNS tunnel.
///
/// There is no public MasterDNS server to test against, so this needs one
/// running locally: tool/masterdns_loop.sh starts the upstream server on
/// 127.0.0.1:5353 for the domain below, and the client uses that address as its
/// resolver. Everything between is real: the engine, its MTU tests, sing-box
/// forwarding into it, and a request that comes back through the tunnel.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> engineRunning() async {
    final ProcessResult r = await Process.run('pgrep', <String>['-fl', 'masterdns']);
    return (r.stdout as String)
        .split('\n')
        .any((String l) => l.contains('Application Support') && l.contains('masterdns'));
  }

  testWidgets('desktop: MasterDNS connects, carries traffic, and cleans up',
      (WidgetTester tester) async {
    final String link = const MasterDnsConfig(
      domains: <String>['t.nova.test'],
      key: '0123456789abcdef0123456789abcdef',
      resolvers: <String>['127.0.0.1:5353'],
      name: 'Loop',
    ).toLink();

    final DesktopProxyController c = DesktopProxyController(manageSystemProxy: false);
    c.selectProfile(ProxyProfile(
      id: 'mdns',
      name: 'Loop',
      kind: ProxyKind.masterdns,
      uri: link,
    ));

    await c.connect();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
    while (c.state != ProxyConnectionState.connected &&
        c.state != ProxyConnectionState.error &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print('MDNS state=${c.state} error=${c.lastError}');
    expect(c.state, ProxyConnectionState.connected,
        reason: 'lastError=${c.lastError}');
    expect(await engineRunning(), isTrue, reason: 'the engine should be up');

    // The key lives in a file only while the engine reads it.
    final Directory support = await getApplicationSupportDirectory();
    expect(File('${support.path}/nova-masterdns.json').existsSync(), isFalse,
        reason: 'the config file holding the key was left behind');

    final HttpClient client = HttpClient()
      ..findProxy = (_) => 'PROXY 127.0.0.1:${c.socksPort}';
    final HttpClientRequest req = await client
        .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'));
    final HttpClientResponse resp = await req.close();
    final String body =
        await resp.transform(const SystemEncoding().decoder).join();
    client.close(force: true);
    // ignore: avoid_print
    print('MDNS trace status=${resp.statusCode} '
        '${body.split('\n').where((String l) => l.startsWith('ip=') || l.startsWith('colo=')).join(' ')}');
    expect(resp.statusCode, 200);
    expect(body, contains('ip='), reason: 'nothing came back through the tunnel');

    await c.disconnect();
    expect(c.state, ProxyConnectionState.disconnected);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(await engineRunning(), isFalse,
        reason: 'the engine never exits by itself, so disconnect must stop it');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
