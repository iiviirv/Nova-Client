import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/update/update_checker.dart';

/// The About footer showed v0.3.3 (82) on build 87: the constants were never
/// bumped. They must match pubspec.yaml's version line on every release.
void main() {
  test('kNovaVersion/kNovaBuild match pubspec.yaml', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch m =
        RegExp(r'^version:\s*([0-9.]+)\+(\d+)\s*$', multiLine: true).firstMatch(pubspec)!;
    expect(kNovaVersion, m.group(1));
    expect(kNovaBuild, m.group(2));
  });

  test('the release tag is the newest CHANGELOG entry', () {
    final String log = File('CHANGELOG.md').readAsStringSync();
    final RegExpMatch m = RegExp(r'^## (v\S+)', multiLine: true).firstMatch(log)!;
    expect(kNovaReleaseTag, m.group(1));
  });
}
