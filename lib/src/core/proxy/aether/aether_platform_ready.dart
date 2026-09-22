import 'dart:async';

/// A queued service start is not proof that Android has installed its route.
Future<void> waitForAetherPlatform(
  Future<String?> Function() status, {
  Duration timeout = const Duration(seconds: 20),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final remaining = timeout - clock.elapsed;
    final state = await status().timeout(remaining);
    if (state == 'connected') return;
    if (state == 'error' || state == 'disconnected' || state == 'disconnecting') {
      throw StateError('The VPN stopped before the Aether tunnel could start.');
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException('The VPN did not become ready for Aether.', timeout);
}
