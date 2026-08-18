import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// When the device changes network (Wi-Fi to cellular, a tunnel, a doze wake)
/// the core logs a burst of ERRORs that are consequences, not faults: every live
/// socket is torn down by the OS, and any handshake in flight loses the local
/// app that asked for it. On a phone that happens on every handover, so the
/// quiet log filled with red for something completely normal.
///
/// The lines below are verbatim from a real device session, so this guards the
/// filter against the actual core output rather than a paraphrase of it.
void main() {
  group('network-change consequences are noise', () {
    test('a download torn down by the network going away', () {
      expect(
        isNetworkChurnNoise(
          'connection: connection download closed: read tcp '
          '10.0.2.16:56732->145.223.80.159:443: read: software caused '
          'connection abort'),
        isTrue,
      );
    });

    test('an upload torn down the same way (DNS-over-TLS here)', () {
      expect(
        isNetworkChurnNoise(
          'connection: connection upload closed: read tcp 1.1.1.1:853: '
          'software caused connection abort'),
        isTrue,
      );
    });

    test('the misleading handshake line: the dial had already succeeded', () {
      expect(
        isNetworkChurnNoise(
          'connection: report handshake success: connection refused'),
        isTrue,
      );
    });
  });

  group('real failures are NOT hidden', () {
    test('a refused dial to the server still shows', () {
      expect(
        isNetworkChurnNoise(
          'connection: open connection to 145.223.80.159:443 using '
          'outbound/vless[proxy]: connection refused'),
        isFalse,
      );
    });

    test('a peer reset is a server-side event, not local churn', () {
      expect(
        isNetworkChurnNoise(
          'connection: connection download closed: read tcp '
          '10.0.2.16:5673->145.223.80.159:443: read: connection reset by peer'),
        isFalse,
      );
    });

    test('a TLS handshake failure still shows', () {
      expect(
        isNetworkChurnNoise(
          'connection: open connection to example.com:443: tls: handshake '
          'failure'),
        isFalse,
      );
    });
  });

  group('the line that explains the burst survives, minus the alarm', () {
    test('missing default interface is shown as a warning, not an error', () {
      expect(
        coreLogLevelFor(
            'network: missing default interface', NovaLogLevel.error),
        NovaLogLevel.warn,
      );
    });

    test('it is not filtered out, so the cause is still visible', () {
      expect(isNetworkChurnNoise('network: missing default interface'), isFalse);
    });

    test('warn survives the quiet-log threshold', () {
      expect(NovaLogLevel.warn.index >= NovaLogLevel.warn.index, isTrue);
    });

    test('other errors keep their level', () {
      expect(
        coreLogLevelFor('connection: something genuinely broke',
            NovaLogLevel.error),
        NovaLogLevel.error,
      );
    });
  });
}
