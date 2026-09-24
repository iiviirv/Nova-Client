import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural, for the same reason `psiphon_lifecycle_test` is: the bug class
/// here is not wrong logic inside a function, it is a function called from one
/// controller and not the other. Nova has two of everything, a mobile core and
/// a desktop one, and `_stopPsiphon` already shipped wired into one of them and
/// not the other. The registration hook is exactly that shape again, so it is
/// checked the same way. No unit test of AetherRegistration can catch a
/// controller that never calls it.
void main() {
  const String mobile = 'lib/src/core/proxy/singbox_proxy_controller.dart';
  const String desktop = 'lib/src/core/proxy/desktop_proxy_controller.dart';

  for (final String path in <String>[mobile, desktop]) {
    test('$path takes the registration when a tunnel comes up', () {
      expect(File(path).readAsStringSync(),
          contains('AetherRegistration.afterConnect('),
          reason: '$path connects tunnels but never takes the WARP '
              'registration, so the fix works on one platform only');
    });
  }
}
