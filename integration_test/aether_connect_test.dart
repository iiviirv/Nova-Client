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
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// What pressing Connect does, minus the platform VPN start.
///
/// The search and the tunnel are proven elsewhere. What has never run is the
/// step between them and the core: taking a SAVED config, starting its tunnel,
/// and producing the config sing-box is handed. That is where a port can be
/// reported that nothing listens on, or a bridge can be built pointing
/// somewhere other than the tunnel that just started, and neither shows up in
/// a test of either half alone.
///
/// The VpnService start itself is not here: it needs a consent dialog, and it
/// is the same call every other protocol already makes.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => AetherTunnel.stop());

  testWidgets('a saved config starts a tunnel and the core config points at it',
      (WidgetTester tester) async {
    final Directory support = await getApplicationSupportDirectory();
    final String base = '${support.path}/aether';
    const AetherOptions options = AetherOptions(scan: AetherScan.turbo);
    final AetherCore core = AetherCore.open();

    // Identity.
    final AetherReply open = core.identityOpen(options, base: base);
    AetherJobStatus st = core.jobPoll((open['job'] as num).toInt());
    for (int i = 0; i < 90 && st.isRunning; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      st = core.jobPoll((open['job'] as num).toInt());
    }
    expect(st.state, AetherJobState.done, reason: 'identity: ${st.error}');
    final int identity = (st.result![kAetherIdentityField] as num).toInt();

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

    // Find a gateway, then SAVE it as a share link and read it back, which is
    // exactly what the editor does and what a stored profile holds.
    final AetherFindResult found = await AetherGatewayFinder(
      attempts: 3,
      scan: (AetherOptions o, List<String> ex) =>
          await_(core.scanStart(identity, o, excluded: ex)),
      verify: (AetherOptions o, String e) async => await_(core.verifyStart(
          identity, o,
          endpoint: e, socks: '127.0.0.1:${await AetherTunnel.freeLoopbackPort()}')),
    ).find(options);
    expect(found.ok, isTrue, reason: 'search: ${found.error}');

    final String link = 'aether://${found.endpoint}'
        '?protocol=masque&scan=turbo&ip=v4&transport=h3#Test';
    final ProxyNode node = parseShareLink(link)!;
    // ignore: avoid_print
    print('AETHER_CONNECT_NODE server=${node.server} port=${node.port} '
        'opts=${node.aetherOpts}');
    expect(node.protocol, NodeProtocol.aether);

    // What connect does with that node.
    final AetherTunnel tunnel = await AetherTunnel.start(
      AetherOptions.fromQuery(node.aetherOpts),
      endpoint: '${node.server}:${node.port}',
      identityBase: base,
    );
    final Map<String, dynamic> cfg =
        SingboxConfig.buildAetherSocksBridgeMap(tunnel.socksPort);

    // The config must point at the tunnel that was just started, not a port
    // chosen independently of it.
    final Map<String, dynamic> out =
        ((cfg['outbounds'] as List<dynamic>).first) as Map<String, dynamic>;
    // ignore: avoid_print
    print('AETHER_CONNECT_BRIDGE tunnel=${tunnel.socksPort} '
        'config=${out['server_port']}');
    expect(out['server_port'], tunnel.socksPort);
    expect(out['server'], '127.0.0.1');

    // And that port must actually be serving, which is the failure a fixed
    // sleep would hide.
    final Socket s = await Socket.connect('127.0.0.1', tunnel.socksPort,
        timeout: const Duration(seconds: 5));
    s.destroy();

    // The WARP ranges must be first in the route, or the core's own dial gets
    // captured by the tunnel it is providing.
    final List<dynamic> rules =
        (cfg['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
    final Map<String, dynamic> first = rules.first as Map<String, dynamic>;
    expect(first['outbound'], 'direct');
    // ignore: avoid_print
    print('AETHER_CONNECT_OK config_bytes=${jsonEncode(cfg).length}');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
