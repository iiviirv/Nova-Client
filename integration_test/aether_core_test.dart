import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

/// Proves the Aether core actually loads and answers on a real device.
///
/// Everything else about this feature is tested on the host, where an Android
/// .so cannot be opened at all. So "the library loads" has until now been an
/// inference from a symbol check in CI, not an observation. This is the test
/// that turns it into one, and it is the failure most likely to be missed
/// otherwise: a packaging mistake looks perfect in every host test and then
/// throws on first use on a phone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('the library opens', () {
    expect(AetherCore.available, isTrue,
        reason: 'libaether.so was not loadable: check the ABI directory name '
            'and that native libs are extracted rather than packed');
  });

  test('a real call crosses the FFI boundary and comes back', () {
    // version() is the cheapest call that proves the whole path: symbol lookup,
    // a C string out of Rust, decoding it, and freeing it without crashing.
    final String? v = AetherCore.open().version();
    expect(v, isNotNull, reason: 'the core loaded but did not answer');
    expect(v, isNotEmpty);
    // ignore: avoid_print
    print('AETHER_VERSION=$v');
  });

  test('a bad call returns an error instead of crashing the app', () {
    // Passing a payload the core will refuse. The point is that a refusal
    // arrives as a readable reply, since this runs in a UI path where an
    // uncaught native failure is a blank screen.
    final AetherReply r = AetherCore.open().identityOpenRaw('{"nonsense":true}');
    expect(r, isNotNull);
    // ignore: avoid_print
    print('AETHER_BAD_CALL ok=${r.ok} error=${r.error}');
  });

  test('scanning without an identity is refused, not crashed', () {
    final AetherReply r =
        AetherCore.open().scanStart(0, const AetherOptions());
    expect(r.ok, isFalse,
        reason: 'job 0 is not a real identity handle');
    expect(r.error, isNotNull);
    // ignore: avoid_print
    print('AETHER_NO_IDENTITY error=${r.error}');
  });
}
