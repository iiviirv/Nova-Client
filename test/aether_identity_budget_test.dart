import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Field log, 2026-09-24, and the answer to a fortnight of confusion.
///
///   20:44:35  Connecting with "WireGuard"        (Wi-Fi, fresh install)
///   20:46:06  identity failed after 90348ms: cancelled
///   20:46:37  Connecting with "WireGuard"        (mobile data)
///   20:46:38  identity ready in 1508ms
///   20:47:28  Connecting with "Gool"             (back on the same Wi-Fi)
///   20:47:29  identity ready in 501ms
///
/// The Wi-Fi blocks Cloudflare's registration call, which WARP makes once
/// before it can connect. Nothing else was wrong: the moment a registration
/// existed, made on mobile data, the same Wi-Fi worked and kept working,
/// because the registration is saved and reused. That is why it looked like a
/// version regression and survived a reboot and a clean reinstall.
///
/// So this was never a gateway problem, and reporting it as one sent everyone
/// looking in the wrong place. Two things follow: registration gets its own
/// short budget, since it either answers in under two seconds or never, and
/// the failure says what actually failed and what to do about it.
void main() {
  test('registration is judged in seconds, not in the search budget', () {
    expect(AetherCoreSearch.identityBudget.inSeconds, lessThanOrEqualTo(30),
        reason: 'a blocked network gave no answer in 90 seconds, and a working '
            'one answers in about one');
    expect(AetherCoreSearch.identityBudget.inSeconds, greaterThanOrEqualTo(5),
        reason: 'working networks were measured at 501ms and 1508ms, so the '
            'budget must leave generous room above that');
  });

  test('it is far shorter than the search it precedes', () {
    // The search cap is 90 seconds. Spending all of it on a step that cannot
    // succeed is the bug this fixes.
    expect(AetherCoreSearch.identityBudget,
        lessThan(const Duration(seconds: 90)));
  });
}
