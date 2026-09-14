import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Aether core ships for every Android ABI Nova builds.
///
/// The library is committed rather than fetched at build time, the same as
/// libbox.aar, so the thing that goes wrong is a missing or truncated file
/// after a partial download. That failure surfaces as the feature being absent
/// on one phone model and fine on another, which is a miserable bug report to
/// receive. Cheaper to fail here.
void main() {
  const Map<String, int> minBytes = <String, int>{
    // Floors, not exact sizes: the build moves with the core. Well under the
    // real figures (5.8, 8.9 and 10.1 MB when built) but far above a truncated
    // file or a git-lfs pointer.
    'armeabi-v7a': 3000000,
    'arm64-v8a': 4000000,
    'x86_64': 4000000,
  };

  test('every ABI Nova ships has the core', () {
    for (final MapEntry<String, int> e in minBytes.entries) {
      final File f =
          File('android/app/src/main/jniLibs/${e.key}/libaether.so');
      expect(f.existsSync(), isTrue,
          reason: 'no Aether core for ${e.key}: the feature would be missing '
              'on those devices only');
      expect(f.lengthSync() >= e.value, isTrue,
          reason: '${e.key} core is ${f.lengthSync()} bytes, too small to be '
              'a real build');
    }
  });

  test('the ABI names match what Android looks for', () {
    // A directory named aarch64 or arm64 instead of arm64-v8a is silently
    // ignored by the packager: the app builds, ships, and cannot find the core.
    final Directory d = Directory('android/app/src/main/jniLibs');
    final Set<String> found = d
        .listSync()
        .whereType<Directory>()
        .map((Directory x) => x.path.split(Platform.pathSeparator).last)
        .toSet();
    expect(found.containsAll(minBytes.keys), isTrue,
        reason: 'found $found');
  });
}
