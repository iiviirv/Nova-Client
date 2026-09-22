import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_startup.dart';

void main() {
  test('late failure keeps the engine reason and cancels the orphan job',
      () async {
    var polls = 0;
    var cancels = 0;
    await expectLater(
        waitForAetherStartup(
          poll: () => ++polls == 1
              ? const AetherJobStatus(AetherJobState.running)
              : const AetherJobStatus(AetherJobState.failed,
                  error: 'TLS access denied'),
          accepts: () async => false,
          cancel: () {
            cancels++;
          },
          timeout: const Duration(seconds: 1),
          interval: Duration.zero,
        ),
        throwsA(isA<AetherUnavailable>()
            .having((e) => e.reason, 'reason', 'TLS access denied')));
    expect(polls, 2);
    expect(cancels, 1);
  });
  test('timeout cancels the job', () async {
    var cancelled = false;
    await expectLater(
        waitForAetherStartup(
          poll: () => const AetherJobStatus(AetherJobState.running),
          accepts: () async => false,
          cancel: () {
            cancelled = true;
          },
          timeout: const Duration(milliseconds: 5),
          interval: Duration.zero,
        ),
        throwsA(isA<AetherUnavailable>()));
    expect(cancelled, isTrue);
  });
  test('a ready port leaves the running job alive', () async {
    var cancelled = false;
    await waitForAetherStartup(
      poll: () => const AetherJobStatus(AetherJobState.running),
      accepts: () async => true,
      cancel: () {
        cancelled = true;
      },
      timeout: const Duration(seconds: 1),
    );
    expect(cancelled, isFalse);
  });
}
