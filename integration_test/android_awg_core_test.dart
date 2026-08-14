import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/proxy/core_features.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Proves on a real Android runtime that the bundled core carries AmneziaWG and
/// can actually pass traffic over it, which neither `flutter analyze` nor a
/// config check can tell you: the app shipped a correct AmneziaWG document to a
/// core without the protocol for months, and everything looked fine.
///
/// Run it against a real AmneziaWG peer:
///
///   1. Start an AmneziaWG server the device can reach. Any will do; the one
///      used when this was written was `amneziawg-go` in userspace on the host,
///      serving HTTP at 10.9.0.1:8080 inside the tunnel, reachable from an
///      emulator at 10.0.2.2:51820.
///   2. Pre-grant the VPN consent dialog, which no test can tap:
///        adb shell appops set online.novaproxy.nova_client ACTIVATE_VPN allow
///   3. flutter test integration_test/android_awg_core_test.dart -d DEVICE \
///        --dart-define=AWG_CONF_B64="$(base64 < peer.conf | tr -d '\n')" \
///        --dart-define=AWG_PROBE_URL=http://10.9.0.1:8080/
///
/// The config is base64 so it survives as one argument. Without it only the
/// capability probe runs, which still fails on a core that has no AmneziaWG.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel control = MethodChannel('nova.proxy/control');
  const String confB64 = String.fromEnvironment('AWG_CONF_B64');
  final String conf =
      confB64.isEmpty ? '' : utf8.decode(base64.decode(confB64));
  const String probeUrl = String.fromEnvironment('AWG_PROBE_URL');

  testWidgets('the bundled core reports AmneziaWG support', (_) async {
    final CoreFeatures features = CoreFeatures();
    await features.load();
    // ignore: avoid_print
    print('core ${features.coreVersion} amneziawg unknown=${features.awgUnknown} '
        'unsupported=${features.awgUnsupported} reason=${features.awgReason}');
    expect(features.awgUnknown, isFalse,
        reason: 'the host must answer the coreFeatures probe');
    expect(features.awgUnsupported, isFalse,
        reason: features.awgReason ?? 'core refused an AmneziaWG endpoint');
  });

  testWidgets('an AmneziaWG tunnel comes up and carries traffic', (_) async {
    if (conf.isEmpty || probeUrl.isEmpty) {
      // ignore: avoid_print
      print('skipped: pass --dart-define=AWG_CONF and --dart-define=AWG_PROBE_URL');
      return;
    }
    final ProxyNode? node = parseShareLink(conf);
    expect(node, isNotNull, reason: 'AWG_CONF must parse as a WireGuard config');

    final String config = SingboxConfig.build(
      node!,
      options: const SingboxRouteOptions(
        blockAds: false,
        bypassIran: false,
        // The probe address is inside the tunnel, and a private one, so the
        // default LAN bypass would send it straight out of the phone instead.
        bypassLan: false,
        lean: true,
      ),
    );
    expect(CoreFeatures.usesAwg(config), isTrue,
        reason: 'the config must be the AmneziaWG one, not plain WireGuard');

    const EventChannel events = EventChannel('nova.proxy/events');
    events.receiveBroadcastStream().listen((dynamic e) {
      // ignore: avoid_print
      print('event: $e');
    });

    await control.invokeMethod<void>('start', <String, dynamic>{
      'configJson': config,
    });
    addTearDown(() async {
      await control.invokeMethod<void>('stop');
    });

    String? state;
    for (int i = 0; i < 30; i++) {
      state = await control.invokeMethod<String>('status');
      if (state == 'connected' || state == 'error') break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(state, 'connected', reason: 'tunnel state after start');

    // The real test: bytes through the tunnel, not a state string.
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    String body = '';
    for (int i = 0; i < 10 && body.isEmpty; i++) {
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(probeUrl));
        final HttpClientResponse res = await req.close();
        body = await res.transform(const SystemEncoding().decoder).join();
      } catch (e) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    // ignore: avoid_print
    print('through the tunnel: $body');
    expect(body, isNotEmpty, reason: 'no traffic passed through the tunnel');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
