import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS packaging stops when Flutter fails even if an old app exists', () async {
    if (!Platform.isMacOS) return;
    final script = File('tool/release_macos.sh').readAsStringSync();
    final start = script.indexOf('echo "############ build macOS');
    final end = script.indexOf('APP=', start);
    final dir = await Directory.systemTemp.createTemp('nova-release-guard');
    addTearDown(() => dir.delete(recursive: true));
    final probe = File('${dir.path}/probe.sh');
    await probe.writeAsString('set -o pipefail\nflutter() { return 17; }\n'
        '${script.substring(start, end)}\necho PACKAGING_CONTINUED\n');
    final result = await Process.run('/bin/zsh', [probe.path]);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('refusing to package an older app'));
    expect(result.stdout, isNot(contains('PACKAGING_CONTINUED')));
  });
}
