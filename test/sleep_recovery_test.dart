import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Reported from the field: after the phone had been put down and picked up
/// again, the connection had to be stopped and started by hand before anything
/// loaded. The orb stayed green throughout, which is the worst version of this,
/// because nothing tells the user their tunnel is dead except that nothing
/// works. Said to affect Aether profiles before and ECH ones now.
///
/// The cause is not established, so the fix is deliberately about the symptom:
/// if the tunnel claims to be connected and carries nothing after a real sleep,
/// Nova does what the user was doing by hand. These are structural, because the
/// behaviour needs a live tunnel, an app lifecycle and a dead network at once,
/// and what actually breaks is a guard being dropped rather than the arithmetic
/// being wrong.
void main() {
  final String src =
      File('lib/src/core/proxy/singbox_proxy_controller.dart').readAsStringSync();

  String body(String signature) {
    final int at = src.indexOf(signature);
    if (at < 0) fail('$signature moved or was renamed');
    int depth = 0;
    int i = src.indexOf('{', at);
    final int start = i;
    for (; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(start, i);
      }
    }
    fail('could not find the end of $signature');
  }

  test('waking the phone checks the tunnel, not just the Aether core', () {
    expect(body('void _onLifecycle('), contains('_recoverAfterSleep()'),
        reason: 'the report was about a tunnel that looked connected and was '
            'not; waking only the Aether core leaves every other profile to '
            'the user to fix by hand');
  });

  test('it only acts on a tunnel that says it is connected', () {
    expect(body('Future<void> _recoverAfterSleep() async {'), contains('_state != ProxyConnectionState.connected'));
  });

  test('a glance at the phone is not a sleep', () {
    expect(body('Future<void> _recoverAfterSleep() async {'), contains('sleepRecoveryAfter'),
        reason: 'reconnecting every time the screen comes on would be worse '
            'than the problem it fixes');
  });

  test('the probe gets a second chance before anything is rebuilt', () {
    expect(
        '_probeInternet()'
            .allMatches(body('Future<void> _recoverAfterSleep() async {'))
            .length,
        greaterThanOrEqualTo(2),
        reason: 'a radio coming back takes a moment, and acting on the first '
            'failure would reconnect on almost every wake');
  });

  test('it cannot act twice in a row', () {
    expect(body('Future<void> _recoverAfterSleep() async {'), contains('sleepRecoveryCooldown'),
        reason: 'a network that is simply down must not turn every glance at '
            'the phone into another reconnect');
  });

  test('it stays out of the way of a heal already running', () {
    expect(body('Future<void> _recoverAfterSleep() async {'), contains('_healing'),
        reason: 'two rebuilds at once is how a tunnel ends up neither up nor '
            'down');
  });
}
