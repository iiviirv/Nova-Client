import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Proves the gateway search actually writes its stages to the log a user can
/// export, against the real core on a real network.
///
/// The host tests cover the wording and the redaction. They cannot cover the
/// thing that matters here, which is that the lines get written at all on the
/// path a person actually runs: every call in that path is FFI, so a search
/// that silently logged nothing would pass every other test in the repo.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a real check of a real address leaves a readable trail', () async {
    NovaLog.instance.clear(NovaLogSource.app);
    const AetherOptions o = AetherOptions(
      mode: AetherMode.masque,
      transport: AetherTransport.h3,
      ip: AetherIpMode.v4,
      scan: AetherScan.balanced,
    );
    final bool ok =
        await AetherCoreSearch().verifyAddress(o, '162.159.198.1:443');
    final String log = NovaLog.instance.export(NovaLogSource.app);
    // ignore: avoid_print
    print('VERIFY_RESULT=$ok');
    // ignore: avoid_print
    print('--- LOG ---\n$log\n--- END ---');
    expect(log, contains('aether search'),
        reason: 'the search ran but wrote nothing a tester could send back');
    expect(log, contains('162.159.198.1:443'));
    expect(log, contains('mode=masque'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
