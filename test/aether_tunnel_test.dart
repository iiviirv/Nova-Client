import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_tunnel.dart';

/// The parts of the tunnel runner that can be checked without a core.
///
/// Starting one needs the native library, so that is proven on a device. What
/// is worth pinning here is the port allocation, because two tunnels or a
/// tunnel and a verification landing on the same port is the kind of collision
/// that shows up as an unrelated connection failing.
void main() {
  test('ports come from the OS, and differ', () async {
    final int a = await AetherTunnel.freeLoopbackPort();
    final int b = await AetherTunnel.freeLoopbackPort();
    expect(a, greaterThan(0));
    expect(b, greaterThan(0));
    expect(a, isNot(b),
        reason: 'picking from a fixed range instead of asking the OS is how a '
            'tunnel and a probe end up fighting over one port');
  });

  test('stopping when nothing runs is not an error', () async {
    // Disconnect calls this unconditionally, including on paths where no Aether
    // config was ever used.
    await AetherTunnel.stop();
    expect(AetherTunnel.live, isNull);
  });
}
