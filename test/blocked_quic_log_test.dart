import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// The core logs every connection it sends to the `block` outbound as an ERROR
/// ("operation not permitted"). That is the anti-QUIC / ad-block feature working
/// (QUIC on a TCP-only exit is blocked so apps fall back to TCP), not a fault, so
/// it must be filtered out of the quiet user-facing log.
void main() {
  test('blocked QUIC (listen packet) lines are recognised as noise', () {
    expect(
      isBlockedConnectionNoise(
        'connection: listen packet connection using  using '
        'outbound/block[block]: operation not permitted'),
      isTrue,
    );
  });

  test('a blocked TCP connection is also noise', () {
    expect(
      isBlockedConnectionNoise(
        'connection: 1.2.3.4:443 using outbound/block[block]: '
        'operation not permitted'),
      isTrue,
    );
  });

  test('a real error is NOT filtered', () {
    expect(
      isBlockedConnectionNoise(
        'connection: report handshake success: connection refused'),
      isFalse,
    );
    expect(isBlockedConnectionNoise('dns: exchange failed for www.google.com'),
        isFalse);
  });
}
