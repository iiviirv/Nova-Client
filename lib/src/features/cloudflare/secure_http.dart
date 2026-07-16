import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;

/// Builds an [http.Client] that dials a caller-chosen IP for each request while
/// still presenting the request's real hostname as the TLS SNI.
///
/// This exists to work around two dart:io facts that together break naive
/// IP-pinning:
///   * A socket returned from a custom `HttpClient.connectionFactory` is used
///     AS-IS. dart:io does NOT upgrade it to TLS for an https URL, so returning
///     a plain [Socket] sends the request in PLAINTEXT over port 443 and
///     Cloudflare answers "400 the plain HTTP request was sent to HTTPS port".
///   * `SecureSocket.startConnect` takes its SNI from the address it dials, so
///     dialing a bare pinned IP would put the IP in the SNI. Some TLS stacks
///     omit an IP SNI and Cloudflare then can't route the connection, stalling
///     the handshake.
/// So we connect the raw socket to the resolved IP ourselves, run
/// `SecureSocket.secure` with the true [Uri.host] (full certificate validation
/// against the real name, plus a hostname SNI every stack accepts), and hand it
/// back through the public [ConnectionTask.fromSocket], which is documented for
/// exactly this use. A stale or wrong IP fails closed on the handshake rather
/// than trusting the wrong server.
///
/// [resolve] returns the IP to dial for a given request URI (system lookup,
/// DoH, a pinned fallback, whatever the caller wants). For non-https URLs the
/// resolved address is dialed directly with no TLS.
http.Client buildSecureClient(
    Future<InternetAddress> Function(Uri uri) resolve) {
  final HttpClient inner = HttpClient();
  inner.connectionFactory =
      (Uri uri, String? proxyHost, int? proxyPort) async {
    final int port = uri.port;
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? port);
    }
    final InternetAddress addr = await resolve(uri);
    if (uri.scheme != 'https') return Socket.startConnect(addr, port);
    final ConnectionTask<Socket> raw = await Socket.startConnect(addr, port);
    final Future<SecureSocket> secured =
        raw.socket.then((Socket s) => SecureSocket.secure(s, host: uri.host));
    return ConnectionTask.fromSocket(secured, raw.cancel);
  };
  return io.IOClient(inner);
}
