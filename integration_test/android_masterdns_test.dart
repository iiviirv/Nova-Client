import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// MasterDNS on a real Android runtime.
///
/// The unit tests cover the decisions. Only a device can say whether Android
/// actually lets the app run the engine from its native library directory
/// (it refuses to run anything from app data), and whether the engine's own
/// queries really leave outside the tunnel so the tunnel can form.
///
///   1. On the host: tool/masterdns_loop.sh -- sleep 100000
///      The emulator reaches the host's loopback at 10.0.2.2.
///   2. adb shell appops set online.novaproxy.nova_client ACTIVATE_VPN allow
///   3. flutter test integration_test/android_masterdns_test.dart -d DEVICE
///
/// Traffic is checked through the loopback port in both modes. In full-device
/// mode this app is deliberately outside its own tunnel, so that port is the
/// only honest way for it to reach the tunnel, and it is the same path the
/// dashboard uses.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String resolver =
      String.fromEnvironment('MDNS_RESOLVER', defaultValue: '10.0.2.2:5353');

  ProxyProfile profile() => ProxyProfile(
        id: 'mdns',
        name: 'Loop',
        kind: ProxyKind.masterdns,
        uri: const MasterDnsConfig(
          domains: <String>['t.nova.test'],
          key: '0123456789abcdef0123456789abcdef',
          resolvers: <String>[resolver],
        ).toLink(),
        updatedAt: DateTime(2026, 9, 17),
      );

  Future<void> waitConnected(SingboxProxyController c) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
    while (c.state != ProxyConnectionState.connected &&
        c.state != ProxyConnectionState.error &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<String> traceVia(int port) async {
    final HttpClient client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = const Duration(seconds: 15);
    String body = '';
    for (int i = 0; i < 8 && !body.contains('ip='); i++) {
      try {
        final HttpClientRequest req = await client
            .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'));
        final HttpClientResponse res = await req.close();
        body = await res.transform(const SystemEncoding().decoder).join();
      } catch (e) {
        // ignore: avoid_print
        print('MDNS attempt $i: $e');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    client.close(force: true);
    return body;
  }

  String summary(String body) => body
      .split('\n')
      .where((String l) => l.startsWith('ip=') || l.startsWith('colo='))
      .join(' ');

  testWidgets('proxy mode: the engine runs and traffic comes back', (_) async {
    final SingboxProxyController c = SingboxProxyController()
      ..proxyPortProvider = (() => 18080);
    c.selectProfile(profile());
    await c.connect();
    await waitConnected(c);
    // ignore: avoid_print
    print('MDNS proxy state=${c.state} error=${c.lastError}');
    expect(c.state, ProxyConnectionState.connected, reason: '${c.lastError}');
    final String body = await traceVia(18080);
    // ignore: avoid_print
    print('MDNS proxy trace: ${summary(body)}');
    expect(body, contains('ip='));
    await c.disconnect();
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('full-device: the tunnel forms and carries traffic', (_) async {
    final SingboxProxyController c = SingboxProxyController();
    c.selectProfile(profile());
    await c.connect();
    await waitConnected(c);
    // ignore: avoid_print
    print('MDNS tun state=${c.state} error=${c.lastError} '
        'loopback=${c.localProxyPort}');
    expect(c.state, ProxyConnectionState.connected, reason: '${c.lastError}');
    expect(c.localProxyPort, isNotNull);
    final String body = await traceVia(c.localProxyPort!);
    // ignore: avoid_print
    print('MDNS tun trace: ${summary(body)}');
    expect(body, contains('ip='),
        reason: 'the engine could not reach its server from inside the '
            'tunnel, so its own traffic is probably being hijacked');
    await c.disconnect();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
