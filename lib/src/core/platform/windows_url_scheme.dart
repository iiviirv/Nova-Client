import 'dart:io';

/// Registers the `nova://` and `novaclient://` URL schemes for the current user
/// on Windows, so a panel's "open in Nova" link launches (or is handed to) the
/// running app.
///
/// Why: Android/iOS/macOS register their schemes in the app manifest, but a
/// Win32 app has to write them to the registry itself, and nothing did, so a
/// `nova://install-config?...` link clicked in a Windows browser did nothing at
/// all. The `app_links` plugin receives the link once the scheme resolves to
/// our exe; it deliberately does not do the registration
/// (see its README_windows.md).
///
/// Written under `HKCU\Software\Classes`, which needs no elevation and follows
/// the user, not the machine. Re-run on every launch: it is idempotent, cheap,
/// and self-heals if the exe was moved (portable zip) or the entry was removed.
/// Only ever registers; never removes another app's handler.
Future<void> registerWindowsUrlSchemes() async {
  if (!Platform.isWindows) return;
  final String exe = Platform.resolvedExecutable;
  for (final String scheme in const <String>['nova', 'novaclient']) {
    await _register(scheme, exe);
  }
}

Future<void> _register(String scheme, String exe) async {
  final String key = r'HKCU\Software\Classes\' + scheme;
  // reg.exe is present on every Windows install and needs no extra dependency.
  // /f overwrites silently so a stale exe path from a previous location is
  // corrected rather than left pointing at nothing.
  final List<List<String>> ops = <List<String>>[
    <String>['add', key, '/ve', '/d', 'URL:Nova Protocol', '/f'],
    <String>['add', key, '/v', 'URL Protocol', '/d', '', '/f'],
    <String>['add', '$key\\DefaultIcon', '/ve', '/d', '"$exe",0', '/f'],
    <String>[
      'add', '$key\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f',
    ],
  ];
  for (final List<String> args in ops) {
    try {
      final ProcessResult r = await Process.run('reg', args, runInShell: false);
      if (r.exitCode != 0) {
        // Best effort: a failure here only means the deep link stays
        // unregistered, exactly the pre-existing state. Never let it affect
        // startup.
        return;
      }
    } catch (_) {
      return;
    }
  }
}
