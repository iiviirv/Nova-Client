import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';

/// Nova's whole diagnostic loop runs on users copying their log out and sending
/// it over Telegram: every field report this project works from arrived that
/// way. A desktop account name is usually the person's legal name, so a log
/// line carrying a home-directory path hands over an identity alongside proof
/// that the sender runs a circumvention client.
void main() {
  test('a macOS home directory loses the account name', () {
    expect(
        NovaLog.redact(
            'looked in /Users/someone/Library/Application Support/nova/aether'),
        'looked in /Users/<user>/Library/Application Support/nova/aether');
  });

  test('a Linux home directory loses the account name', () {
    expect(NovaLog.redact('wrote /home/someone/.local/share/nova/core.log'),
        'wrote /home/<user>/.local/share/nova/core.log');
  });

  test('a Windows home directory loses the account name', () {
    expect(
        NovaLog.redact(r'wrote C:\Users\Someone Real\AppData\Roaming\nova'),
        r'wrote C:\Users\<user> Real\AppData\Roaming\nova');
  });

  test('more than one path in a line is masked, not just the first', () {
    expect(
        NovaLog.redact('copy /Users/aa/x to /Users/bb/y'),
        'copy /Users/<user>/x to /Users/<user>/y');
  });

  test('a path with no account name is left alone', () {
    expect(NovaLog.redact('wrote /var/log/nova.log'), 'wrote /var/log/nova.log');
    expect(NovaLog.redact('/Users/'), '/Users/');
  });

  test('the credential masking it sits beside still works', () {
    expect(
        NovaLog.redact(
            'vless://11111111-2222-3333-4444-555555555555@h:443?key=abc'),
        'vless://<uuid>@h:443?key=<token>');
  });
}
