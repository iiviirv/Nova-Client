import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Field report, build 167: connected through Psiphon over WARP, the address
/// and country on the dashboard disagreed with what a site like whatsmyip
/// reported. The tunnel was fine; the reading was not.
///
/// Cause: to build its tunnel, the Psiphon engine has to dial out rather than
/// into it, so this app is excluded from its own VPN while Psiphon runs. That
/// exclusion covers the whole app, including the dashboard's own probe, which
/// then went out over the bare network and read back the user's real address.
/// `_selfExcluded` knew about per-app routing and MasterDNS but not Psiphon, so
/// the probe was never pointed at the loopback inbound.
///
/// Structural, for the same reason as the stranded-engine test: this was a
/// condition missing a term, not wrong logic, and every unit test passed while
/// it shipped. The comment above proxyUri already described the symptom.
void main() {
  test('Psiphon counts as putting this app outside its own tunnel', () {
    final String src =
        File('lib/src/core/proxy/singbox_proxy_controller.dart')
            .readAsStringSync();
    final int at = src.indexOf('bool get _selfExcluded');
    expect(at, isNot(-1), reason: '_selfExcluded moved or was renamed');
    final String expr = src.substring(at, src.indexOf(';', at));
    for (final String term in <String>[
      '_perAppActive',
      '_masterDnsActive',
      '_psiphonActive',
    ]) {
      expect(expr, contains(term),
          reason: '$term must make the app use its loopback inbound, or the '
              'dashboard reports the real address as the exit');
    }
  });

  test('the flag is raised when Psiphon takes the app out of the tunnel', () {
    final String src =
        File('lib/src/core/proxy/singbox_proxy_controller.dart')
            .readAsStringSync();
    final int at = src.indexOf('Future<String> _buildPsiphonConfig');
    expect(at, isNot(-1));
    final String body = src.substring(at, at + 4000);
    expect(body, contains('_psiphonActive = true;'));
  });
}
