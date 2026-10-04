import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Field report, build 180: every Aether profile failed with "The Aether core
/// is unavailable: libaether.so was not found beside the app". The library was
/// in the APK. It would not load.
///
/// The v2.3.0 core gained a dependency the v2.0.0 one did not have,
/// libc++_shared.so, which Android does not provide and Nova did not ship.
/// Every other engine here is self-contained (the Go ones need no C++ runtime,
/// and the old Aether did not either), so nothing had ever needed it, and
/// nothing noticed when something started to.
///
/// This had been broken since build 177 and was found two builds later, only
/// because a tester opened an Aether profile. A missing shared library is not
/// something any Dart test can discover by running code, so it is checked here
/// against what the ELF files actually declare.
void main() {
  const List<String> abis = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];

  /// The DT_NEEDED entries of an ELF shared object, read straight out of the
  /// file: the dynamic string table, filtered to the library's own needs.
  Set<String> needed(File f) {
    final List<int> b = f.readAsBytesSync();
    final Set<String> out = <String>{};
    // Rather than parse the full ELF, take every NUL-terminated string in the
    // file that looks like a shared library name. Coarse, but it cannot miss a
    // DT_NEEDED entry, which is the only way this test could give a false pass.
    final StringBuffer cur = StringBuffer();
    for (final int c in b) {
      if (c == 0) {
        final String s = cur.toString();
        if (s.endsWith('.so') && s.length < 64 && !s.contains('/')) out.add(s);
        cur.clear();
      } else if (c >= 32 && c < 127) {
        cur.writeCharCode(c);
      } else {
        cur.clear();
      }
    }
    return out;
  }

  for (final String abi in abis) {
    test('$abi ships every library libaether asks for', () {
      final File lib = File('android/app/src/main/jniLibs/$abi/libaether.so');
      expect(lib.existsSync(), isTrue, reason: '${lib.path} is missing');
      final Set<String> deps = needed(lib);
      // The ones Android provides itself.
      const Set<String> system = <String>{
        'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so',
      };
      for (final String d in deps.where((String d) => !system.contains(d))) {
        final File beside = File('android/app/src/main/jniLibs/$abi/$d');
        expect(beside.existsSync(), isTrue,
            reason: 'libaether.so needs $d, which Android does not provide and '
                'this build does not ship, so dlopen fails and every Aether '
                'profile reports the core as unavailable');
      }
    });

    test('$abi carries the C++ runtime the v2.3.0 core needs', () {
      // Named outright rather than left to the loop, because this is the exact
      // file whose absence broke three builds.
      expect(File('android/app/src/main/jniLibs/$abi/libc++_shared.so')
          .existsSync(), isTrue);
    });
  }
}
