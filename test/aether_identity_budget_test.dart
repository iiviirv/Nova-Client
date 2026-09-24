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
  test('registration is given long enough for the camouflaged route', () {
    // The core does not make one call. When the direct one is blocked it
    // retries over random Cloudflare edge addresses with a split client hello
    // and four TLS fingerprints, up to twenty attempts allowed twenty nine
    // seconds each. That is the only thing that can succeed on a network which
    // blocks the direct call, so the budget has to cover it. A first attempt
    // at this fix used fifteen seconds, which would have killed the workaround
    // before it started.
    expect(AetherCoreSearch.identityBudget,
        greaterThanOrEqualTo(const Duration(minutes: 2)),
        reason: 'shorter than this cuts off the only route that can work');
  });

  test('the user is told before the silence gets long', () {
    expect(AetherCoreSearch.identityQuickPath,
        lessThan(const Duration(seconds: 30)),
        reason: 'a working network registers in about a second, so past a few '
            'seconds something slower is running and saying so is the '
            'difference between a wait and an apparent hang');
    expect(AetherCoreSearch.identityQuickPath,
        lessThan(AetherCoreSearch.identityBudget));
  });
}
