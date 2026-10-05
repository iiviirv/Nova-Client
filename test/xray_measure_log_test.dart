import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Field report: a tester's xhttp server failed every delay test while his
/// other servers passed, and nothing in the log could say why. The reason was
/// not the node. The measuring path started the Xray core without installing a
/// logger, so Xray's own transport errors went nowhere and all that surfaced
/// was the Clash API's generic "An error occurred in the delay test".
///
/// The tunnel path had always done this, and its comment even names the exact
/// failure it prevents: "an xhttp transport error on an xhttp node is
/// invisible". The measuring path was the one place that started Xray silently,
/// which is the one place an xhttp node is judged dead.
void main() {
  final String measure = File(
          'android/app/src/main/kotlin/online/novaproxy/nova_client/NovaMeasure.kt')
      .readAsStringSync();
  final String tunnel = File(
          'android/app/src/main/kotlin/online/novaproxy/nova_client/NovaVpnService.kt')
      .readAsStringSync();

  test('measuring installs a logger before starting Xray', () {
    final int logger = measure.indexOf('Novaxray.setLogger(');
    final int start = measure.indexOf('Novaxray.start(');
    expect(logger, isNot(-1),
        reason: 'without it an xhttp node that fails cannot say why, which is '
            'the whole reason this test exists');
    expect(logger, lessThan(start),
        reason: 'a logger installed after the core starts misses whatever it '
            'said while starting');
  });

  test('and clears it when the run ends, as the tunnel does', () {
    expect(measure, contains('Novaxray.setLogger(null)'),
        reason: 'a logger left attached outlives the run and writes into a '
            'dead callback');
  });

  test('both paths tag the lines the same way, so a log reads as one thing', () {
    for (final String src in <String>[measure, tunnel]) {
      expect(src, contains(r'"[xray] $msg"'));
      expect(src, contains('"level" to 3'),
          reason: 'warn, so the lines survive the quiet filter the user sees');
    }
  });
}
