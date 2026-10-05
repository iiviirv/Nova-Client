import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The bug this exists to prevent, stated plainly: a tester could not connect
/// at all on a brand new phone, with ECH on and nothing cached. The key fetch
/// did not succeed on his network, Nova fell back to the key built into the
/// app, Cloudflare had rotated since that build, and a stale key is not
/// "slightly less private". It is refused by every server, so every single
/// connection failed with a certificate for cloudflare-ech.com.
///
/// The rule now: never send a key that cannot be vouched for. A connection
/// without ECH may work. A connection with a stale key cannot.
void main() {
  for (final String path in <String>[
    'lib/src/core/proxy/singbox_proxy_controller.dart',
    'lib/src/core/proxy/desktop_proxy_controller.dart',
  ]) {
    final String src = File(path).readAsStringSync();

    test('$path turns ECH off when there is no key', () {
      expect(src, contains('ech: profile.echSni && echKey != null'),
          reason: 'sending ECH with a key we could not fetch is the failure '
              'this whole file is about');
    });

    test('$path says so in the log rather than failing quietly', () {
      expect(src, contains('no key could be fetched'),
          reason: 'the first report of this took two rounds to diagnose '
              'because nothing in the log said the key was the problem');
    });
  }

  test('the built-in key is not what gets sent when the fetch fails', () {
    final String src =
        File('lib/src/core/proxy/ech_key.dart').readAsStringSync();
    expect(src, isNot(contains('return kCloudflareEchConfig;')),
        reason: 'returning the built-in key on failure is the exact line that '
            'caused this');
  });

  test('BOTH cores measure with the key, not just the flag', () {
    // The reason this is a loop and not a single check: the measuring fix went
    // into the mobile controller and not the desktop one, so Windows reported
    // 0 of 17 servers answering while the identical build worked on Android.
    // Nova has two controllers and this project has now been bitten by that
    // four times; a test that names only one of them is how.
    for (final String path in <String>[
      'lib/src/core/proxy/singbox_proxy_controller.dart',
      'lib/src/core/proxy/desktop_proxy_controller.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('measureEchKey'),
          reason: '$path measures with the ECH flag set and the key left at '
              'its default, which is the built-in one, which goes stale within '
              'days and makes every server read as dead');
      expect(src, contains('echConfig: measureEchKey ?? kCloudflareEchConfig'),
          reason: '$path sets the flag without passing the key');
      expect(src,
          contains('ech: _active?.echSni == true && measureEchKey != null'),
          reason: '$path keeps ECH on while measuring even with no key');
    }
  });

  test('the lightning test is measured with the same key it will dial with',
      () {
    // Field log, 1.30.1: every free server failed its delay test with HTTP 503
    // while the server the user picked connected perfectly. The measuring
    // config set the ECH flag and left the key at its default, which is the
    // built-in one, which goes stale within days. Setting the flag is not the
    // setting; the key is.
    final String src =
        File('lib/src/core/proxy/singbox_proxy_controller.dart')
            .readAsStringSync();
    final int at = src.indexOf('routeOptions.copyWith(');
    expect(at, isNot(-1), reason: 'the measuring options moved');
    final String block = src.substring(at, at + 800);
    expect(block, contains('echConfig:'),
        reason: 'measuring with the flag but not the key reports every server '
            'dead, which is worse than not measuring at all');
    expect(block, contains('measureEchKey'));
  });

  test('measuring turns ECH off when there is no key, as connecting does', () {
    final String src =
        File('lib/src/core/proxy/singbox_proxy_controller.dart')
            .readAsStringSync();
    expect(src, contains('_active?.echSni == true && measureEchKey != null'));
  });
}
