@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The bug this guards: the macOS cores shipped claiming they needed the newest
/// macOS.
///
/// A cgo build takes its minimum from the host SDK unless it is told otherwise,
/// so cores built on a Mac running the newest macOS were stamped with that same
/// version. The machine that builds them can always run them, so nothing here
/// ever noticed; the people it reaches are the ones on older machines, and an
/// Intel Mac cannot run the newest macOS at all.
///
/// Checked in the test suite as well as in the build script, because the build
/// script only runs when someone rebuilds a core, and this file is what a
/// rebuilt core has to get past to be committed.
void main() {
  const double newestSupported = 12.0;

  double minos(String path) {
    final ProcessResult r =
        Process.runSync('vtool', <String>['-show-build', path]);
    final RegExpMatch? m =
        RegExp(r'minos\s+([0-9.]+)').firstMatch(r.stdout.toString());
    expect(m, isNotNull, reason: 'no minos in vtool output for $path');
    return double.parse(m!.group(1)!);
  }

  for (final String core in <String>[
    'assets/bin/sing-box-macos-arm64',
    'assets/bin/sing-box-macos-amd64',
  ]) {
    test('$core runs on macOS $newestSupported and older', () {
      if (!File(core).existsSync()) {
        markTestSkipped('$core is not in this checkout');
        return;
      }
      expect(minos(core), lessThanOrEqualTo(newestSupported),
          reason: 'built without MACOSX_DEPLOYMENT_TARGET, so it demands the '
              'macOS of whichever machine built it');
    });
  }
}
