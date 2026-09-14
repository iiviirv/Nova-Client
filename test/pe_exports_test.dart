import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Windows export reader, checked against a DLL that is already in the
/// repo.
///
/// It exists because CI needs to confirm the Aether core exports what the Dart
/// binding calls, and the usual tool for that (dumpbin) is not reachable from a
/// plain shell on a runner. Reaching for it broke the build twice. A test here
/// means the next person to touch the reader finds out locally in a second
/// rather than in a Windows CI leg ten minutes later.
void main() {
  test('it lists real exports from a real DLL', () {
    final File dll = File('assets/bin/libcronet.dll');
    if (!dll.existsSync()) {
      markTestSkipped('libcronet.dll is not in this checkout');
      return;
    }
    final ProcessResult r = Process.runSync(
        'python3', <String>['tool/pe_exports.py', dll.path]);
    expect(r.exitCode, 0, reason: 'reader failed: ${r.stderr}');
    final List<String> names = (r.stdout as String)
        .split('\n')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    expect(names.length, greaterThan(100),
        reason: 'a DLL with 273 exports came back with ${names.length}');
    expect(names.any((String n) => n.startsWith('Cronet_')), isTrue,
        reason: 'the names do not look like real exports');
  });

  test('a file that is not a PE is rejected, not silently empty', () {
    // Returning nothing for a bad file would read as "no exports", which in CI
    // means a missing symbol, which points at the library instead of the input.
    final ProcessResult r = Process.runSync(
        'python3', <String>['tool/pe_exports.py', 'pubspec.yaml']);
    expect(r.exitCode, isNot(0));
  });
}
