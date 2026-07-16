import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nova_client/src/features/cloudflare/secure_http.dart';

/// Regression guard for the Cloudflare-connect bug: a socket returned from a
/// custom `HttpClient.connectionFactory` is used as-is, so an earlier version
/// that returned a plain `Socket` shipped every https request in PLAINTEXT and
/// Cloudflare answered "400 the plain HTTP request was sent to HTTPS port".
/// [buildSecureClient] must run TLS itself, so the very first bytes it writes
/// have to be a TLS ClientHello, never an ASCII HTTP request line.
void main() {
  test('buildSecureClient sends a TLS ClientHello, never plaintext HTTP',
      () async {
    // A plain TCP server that never speaks TLS. We only capture what the client
    // writes first, then let the doomed request error out.
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final Completer<List<int>> firstBytes = Completer<List<int>>();
    server.listen((Socket sock) {
      sock.listen(
        (List<int> data) {
          if (!firstBytes.isCompleted && data.isNotEmpty) {
            firstBytes.complete(data);
          }
        },
        onError: (_) {},
        cancelOnError: true,
      );
    });

    // Resolver dials loopback for any URI, so the request reaches our server
    // even though its host is a different (invalid) name — proving the dial-IP
    // and the SNI/host are decoupled.
    final http.Client client =
        buildSecureClient((Uri uri) async => InternetAddress.loopbackIPv4);

    unawaited(client
        .get(Uri.parse('https://example.invalid:${server.port}/'))
        .timeout(const Duration(seconds: 5))
        .then((_) {}, onError: (_) {}));

    final List<int> bytes =
        await firstBytes.future.timeout(const Duration(seconds: 5));

    // A TLS record begins with content-type 0x16 (handshake) then version 0x03.
    // Plaintext HTTP would begin with an ASCII method byte, e.g. 'G' (0x47).
    expect(bytes.first, 0x16,
        reason: 'first byte must be a TLS handshake record (0x16), not '
            'plaintext HTTP — that plaintext was the original bug');
    expect(bytes[1], 0x03, reason: 'TLS record version high byte');
    expect(String.fromCharCode(bytes.first), isNot('G'));

    client.close();
    await server.close();
  });

  test('buildSecureClient validates the certificate against the real host',
      () async {
    // Dial a live Cloudflare edge IP but claim a hostname its cert cannot cover:
    // TLS must fail closed (throw), never silently trust the wrong server.
    final http.Client client = buildSecureClient(
        (Uri uri) async => InternetAddress('104.17.110.184')); // a dash edge
    await expectLater(
      client
          .get(Uri.parse('https://not-a-cloudflare-name.invalid/'))
          .timeout(const Duration(seconds: 10)),
      throwsA(anything),
    );
    client.close();
  }, tags: <String>['network']);
}
