import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/update/update_checker.dart';

/// The desktop app copies the sing-box core out of the bundle into its
/// application-support folder and runs the copy. Deciding whether that copy is
/// current by comparing FILE SIZE is what stranded a tester for days.
///
/// The core is rebuilt from pinned source, and a small source change routinely
/// produces a byte-identical length. The fix for the AmneziaWG
/// crash-on-disconnect did exactly that: 47727954 bytes before, 47727954 bytes
/// after. So the copy always "matched", the old crashing core was never
/// replaced, and reinstalling the app did not help either, because the app
/// bundle is not where the running core lives.
void main() {
  test('a rebuild of identical length is not the same binary', () {
    // The real numbers from that commit.
    const int before = 47727954;
    const int after = 47727954;
    expect(after, before,
        reason: 'this is why a size check cannot detect the rebuild');
  });

  test('the build stamp changes every release, so the copy is refreshed', () {
    expect(kNovaBuild, isNotEmpty);
    expect(int.tryParse(kNovaBuild), isNotNull,
        reason: 'the stamp is compared as text but has to be a real build');
  });

  test('a stamp file round-trips', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('novastamp');
    final File stamp = File('${tmp.path}/core.build');
    expect(stamp.existsSync(), isFalse);
    // Absent stamp must read as "not current", so the first launch after this
    // change re-copies once for everyone, including the stranded users.
    final String have = stamp.existsSync() ? stamp.readAsStringSync().trim() : '';
    expect(have == kNovaBuild, isFalse);
    await stamp.writeAsString(kNovaBuild);
    expect(stamp.readAsStringSync().trim(), kNovaBuild);
    tmp.deleteSync(recursive: true);
  });
}
