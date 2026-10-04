import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural, for the reason the project has learned twice: a setting the
/// controller never reads is a setting that silently does nothing, and no test
/// of the setting itself can tell. Deleting the spec from these two call sites
/// broke nothing until this existed.
void main() {
  for (final String path in <String>[
    'lib/src/core/proxy/singbox_proxy_controller.dart',
    'lib/src/core/proxy/desktop_proxy_controller.dart',
  ]) {
    test('$path looks the key up where the profile says to', () {
      expect(File(path).readAsStringSync(),
          contains('EchSpec.parse(profile.echConfigList)'),
          reason: 'an editable lookup the connection ignores is worse than no '
              'editor at all: it looks answered');
    });
  }
}
