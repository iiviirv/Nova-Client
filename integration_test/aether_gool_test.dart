import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';

/// What a gool search actually returns, and whether one address is enough to
/// open the tunnel with.
///
/// gool is WARP inside WARP, so it has two hops. The core's own help says the
/// scan finds both unless you name them, but its tunnel payload carries a
/// single `peer` and no second hop. Those two facts cannot both be the whole
/// story, and guessing which gives way is how the editor ended up shipping a
/// gool config that saves and then cannot connect.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async => AetherTunnel.stop());

  testWidgets('a gool scan, and what it takes to tunnel with it',
      (WidgetTester tester) async {
    final Directory support = await getApplicationSupportDirectory();
    final String base = '${support.path}/aether';
    const AetherOptions gool =
        AetherOptions(mode: AetherMode.gool, scan: AetherScan.turbo);
    final AetherCore core = AetherCore.open();

    final AetherReply open = core.identityOpen(gool, base: base);
    AetherJobStatus st = core.jobPoll((open['job'] as num).toInt());
    for (int i = 0; i < 90 && st.isRunning; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      st = core.jobPoll((open['job'] as num).toInt());
    }
    expect(st.state, AetherJobState.done, reason: 'identity: ${st.error}');
    final int id = (st.result![kAetherIdentityField] as num).toInt();

    Future<AetherJobStatus> run(AetherReply started, {int minutes = 4}) async {
      if (!started.ok) {
        return AetherJobStatus(AetherJobState.failed, error: started.error);
      }
      final int job = (started['job'] as num).toInt();
      AetherJobStatus s = core.jobPoll(job);
      final DateTime end = DateTime.now().add(Duration(minutes: minutes));
      while (s.isRunning && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        s = core.jobPoll(job);
      }
      return s;
    }

    // 1. What does a gool scan hand back? One address, or a pair?
    final AetherJobStatus scan = await run(core.scanStart(id, gool));
    // ignore: avoid_print
    print('AETHER_GOOL_SCAN state=${scan.state} result=${scan.result} '
        'error=${scan.error}');
    expect(scan.state, AetherJobState.done, reason: 'gool scan: ${scan.error}');

    final String? endpoint = AetherEndpoint.parse(scan.result?['endpoint']);
    // ignore: avoid_print
    print('AETHER_GOOL_ENDPOINT=$endpoint');

    // 2. Is that one address enough to open a gool tunnel, or does the core
    //    want the second hop named too?
    if (endpoint != null) {
      final int port = await AetherTunnel.freeLoopbackPort();
      final AetherJobStatus verify = await run(
          core.verifyStart(id, gool, endpoint: endpoint, socks: '127.0.0.1:$port'));
      // ignore: avoid_print
      print('AETHER_GOOL_VERIFY state=${verify.state} error=${verify.error} '
          'result=${verify.result}');
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
