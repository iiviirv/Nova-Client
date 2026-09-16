import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// A reference table for reading a tester's log.
///
/// The core answers a verification with nothing but `reachable`, so the only
/// other thing a failure carries is how long it took. That number is only
/// worth anything next to known cases, which is what this measures: a good
/// endpoint, a black hole, and a live address with the wrong port, from a
/// network where MASQUE is known to work.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> probe(String label, String endpoint,
      {AetherTransport transport = AetherTransport.h3}) async {
    NovaLog.instance.clear(NovaLogSource.app);
    final AetherOptions o = AetherOptions(
      mode: AetherMode.masque,
      transport: transport,
      ip: AetherIpMode.v4,
      scan: AetherScan.balanced,
    );
    final Stopwatch clock = Stopwatch()..start();
    final bool ok = await AetherCoreSearch().verifyAddress(o, endpoint);
    // ignore: avoid_print
    print('MATRIX  ${label.padRight(28)} ok=$ok  '
        'wall=${clock.elapsedMilliseconds}ms');
    for (final NovaLogEntry e in NovaLog.instance.lines(NovaLogSource.app)) {
      if (e.message.contains('took')) {
        // ignore: avoid_print
        print('MATRIX    ${e.message}');
      }
    }
  }

  test('known cases, so a failure elsewhere can be read', () async {
    await probe('good endpoint h3', '162.159.198.1:443');
    await probe('good endpoint h2', '162.159.198.1:443',
        transport: AetherTransport.h2);
    await probe('black hole', '192.0.2.1:443');
    await probe('live host, dead port', '162.159.198.1:444');
    await probe('wireguard port, masque', '162.159.198.1:2408');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
