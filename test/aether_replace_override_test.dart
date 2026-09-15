import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The gateway replacement is implemented, not inherited.
///
/// The base class declares it with a `false` default so any controller compiles
/// without it. That is convenient and dangerous in the same move: delete the
/// override and the offer still appears, the user accepts, and it reports that
/// no gateway answered. A silent no rather than a crash, on the one path that
/// exists to rescue a connection already failing.
///
/// Dart has no reflection here, so this reads the source. Crude, and it still
/// fails if the override is removed, which is the whole job.
void main() {
  test('the sing-box controller implements replaceAetherGateway', () {
    final File f =
        File('lib/src/core/proxy/singbox_proxy_controller.dart');
    expect(f.existsSync(), isTrue);
    final String src = f.readAsStringSync();
    expect(src.contains('Future<bool> replaceAetherGateway'), isTrue,
        reason: 'without this override the base class answers false, so the '
            'offer would report "no gateway answered" without ever searching');
    // It must actually do the search, not just exist.
    expect(src.contains('AetherCoreSearch'), isTrue,
        reason: 'the replacement has to run a search');
    expect(src.contains('excludedFirst'), isTrue,
        reason: 'and exclude the address that just failed, or the search tends '
            'to hand the same one back');
  });
}
