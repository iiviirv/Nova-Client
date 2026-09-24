import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Field report, build 165 on Irancell: Psiphon was started and never stopped
/// on a normal disconnect. The engine kept retrying its servers for the life of
/// the app, and on a network where those servers are blocked that traffic
/// competed with everything Nova did next. An Aether identity open that
/// normally takes 500ms took 124 seconds, so WireGuard and Gool stopped finding
/// gateways at all. One missing call broke two features that had nothing to do
/// with Psiphon.
///
/// This is a structural test rather than a behavioural one, deliberately. The
/// bug was not wrong logic inside a function; it was a function not called from
/// somewhere its sibling is called. Nova runs several engines with the same
/// lifetime, and the failure mode is adding a new one and stopping it in fewer
/// places than the others. Comparing the call sites catches exactly that, and
/// nothing else does: every unit test of the engine passed while this shipped.
void main() {
  String source(String path) => File(path).readAsStringSync();

  /// The body of a named method, so the assertion is about that method rather
  /// than about the file containing the string somewhere.
  String methodBody(String path, String signature) {
    final String src = source(path);
    final int at = src.indexOf(signature);
    expect(at, isNot(-1), reason: '$signature moved or was renamed');
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

  test('disconnect stops the Psiphon engine', () {
    // This is the call that was missing. Every unit test of the engine passed
    // while it was, because nothing tested who calls it.
    final String body = methodBody(
        'lib/src/core/proxy/singbox_proxy_controller.dart',
        'Future<void> disconnect()');
    expect(body, contains('_stopMasterDns();'),
        reason: 'the sibling engine is stopped here; this anchors the test');
    expect(body, contains('_stopPsiphon();'),
        reason: 'a Psiphon engine left running keeps retrying its servers for '
            'the life of the app. On a network where they are blocked that '
            'starved everything else: an Aether identity that takes 500ms took '
            '124 seconds, and WireGuard and Gool stopped finding gateways.');
  });

  test('the desktop teardown stops it too', () {
    const String path = 'lib/src/core/proxy/desktop_proxy_controller.dart';
    expect(source(path), contains('_stopPsiphon();'));
  });

  test('a stop started from the notification also stops the engine', () {
    // The Android notification action tells the service directly and
    // disconnect() never runs, so the engine in this app's process would keep
    // going. A tester saw Nova switch off while the key icon stayed and the
    // system VPN was still up. The host's state event is the one thing every
    // stop path produces, so the engine is stopped from there too.
    final String body = methodBody(
        'lib/src/core/proxy/singbox_proxy_controller.dart', 'void _onEvent(');
    expect(body, contains('_stopPsiphon();'),
        reason: 'the host state event is the only thing every stop path '
            'produces, so the engine has to be stopped from there');
  });
}
