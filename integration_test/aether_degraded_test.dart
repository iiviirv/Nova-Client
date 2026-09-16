import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Does a slow, lossy path turn a good gateway into an unhealthy one?
///
/// The core gives verification a fixed five second budget and reports every
/// failure identically, so the question cannot be answered by reading a log
/// from a bad network. It can be answered here, by making this network bad on
/// purpose and watching a gateway that is known good fail anyway. Driven by
/// tool/iran_sim.sh, which owns the latency and the teardown.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a known-good gateway, three times', () async {
    const AetherOptions o = AetherOptions(
      mode: AetherMode.masque,
      transport: AetherTransport.h3,
      ip: AetherIpMode.v4,
      scan: AetherScan.balanced,
    );
    for (int i = 1; i <= 3; i++) {
      NovaLog.instance.clear(NovaLogSource.app);
      final bool ok =
          await AetherCoreSearch().verifyAddress(o, '162.159.198.1:443');
      String took = 'unknown';
      for (final NovaLogEntry e in NovaLog.instance.lines(NovaLogSource.app)) {
        if (e.message.contains('took')) took = e.message.split('took').last;
      }
      // ignore: avoid_print
      print('DEGRADED  run $i  ok=$ok  took$took');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
