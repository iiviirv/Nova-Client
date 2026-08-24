@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The mechanism behind the "full-device mode needs administrator access"
/// reports.
///
/// An app installed from a DMG has every file inside it quarantined. Nova copies
/// its core out of the bundle before running it, and this is the step that broke
/// it: File.copy carries `com.apple.quarantine` onto the copy, which has no
/// notarization ticket of its own, so Gatekeeper kills it. Exit 137, nothing on
/// stdout or stderr, no log. With no log the app used to guess that the admin
/// prompt had been dismissed, which is why running the whole app under sudo
/// changed nothing and why the advice was impossible to act on.
///
/// It never reproduced on a development machine, because a locally built app is
/// not quarantined. That is how it survived as an "Intel Mac" bug: the only
/// Intel tester was also the only one installing from the DMG.
///
/// The kill itself is not asserted here. Executing a quarantined Mach-O sends
/// Gatekeeper to Apple for a verdict, which is slow and needs a network, so it
/// belongs in a manual check rather than the suite. It was confirmed by hand:
/// the bundled core exits 137 with no output while quarantined, and runs
/// normally the moment the attribute is removed. What is asserted here is the
/// part that is fast, offline and deterministic, and it is the part
/// DesktopProxyController._unquarantine exists to undo.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nova-quarantine');
  });

  tearDown(() => tmp.delete(recursive: true));

  test('File.copy carries the quarantine attribute onto the copy', () async {
    final File src = File('${tmp.path}/src');
    await src.writeAsString('x');
    await Process.run('xattr', <String>[
      '-w',
      'com.apple.quarantine',
      '0083;00000000;Safari;',
      src.path,
    ]);

    final File copy = await src.copy('${tmp.path}/staged');
    final ProcessResult after = await Process.run('xattr', <String>[copy.path]);
    expect(after.stdout.toString(), contains('com.apple.quarantine'),
        reason: 'if this ever stops being true, the staging step no longer '
            'needs to strip the attribute');
  });

  test('removing the attribute leaves the file otherwise untouched', () async {
    final File f = File('${tmp.path}/f');
    await f.writeAsString('contents');
    await Process.run('xattr', <String>[
      '-w',
      'com.apple.quarantine',
      '0083;00000000;Safari;',
      f.path,
    ]);
    // Exactly what _unquarantine runs.
    await Process.run('xattr', <String>['-d', 'com.apple.quarantine', f.path]);
    final ProcessResult after = await Process.run('xattr', <String>[f.path]);
    expect(after.stdout.toString(), isNot(contains('com.apple.quarantine')));
    expect(await f.readAsString(), 'contents');
  });

  test('stripping a file that was never quarantined is harmless', () async {
    // The staging path calls this unconditionally, including on a locally built
    // app where there is nothing to strip.
    final File f = File('${tmp.path}/clean');
    await f.writeAsString('contents');
    await Process.run('xattr', <String>['-d', 'com.apple.quarantine', f.path]);
    expect(await f.readAsString(), 'contents');
  });
}
