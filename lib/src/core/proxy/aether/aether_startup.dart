import 'aether_core.dart';
import 'aether_protocol.dart';

/// Watch the engine job as well as its socket so a late engine failure is not
/// hidden behind a generic port timeout. Failed startup must release the job.
Future<void> waitForAetherStartup({
  required AetherJobStatus Function() poll,
  required Future<bool> Function() accepts,
  required void Function() cancel,
  required Duration timeout,
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final clock = Stopwatch()..start();
  try {
    while (clock.elapsed < timeout) {
      final status = poll();
      if (!status.isRunning) {
        throw AetherUnavailable(
            status.error ?? 'the tunnel stopped during startup');
      }
      if (await accepts()) return;
      await Future<void>.delayed(interval);
    }
    throw AetherUnavailable(
        'the tunnel did not open its local proxy before the startup deadline');
  } catch (_) {
    try {
      cancel();
    } catch (_) {}
    rethrow;
  }
}
