import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io;

/// Google "ghs" front IPs (Google Hosted Services / GFE anycast). These edges
/// serve many `*.google.com` tenants on one IP pool and route by the inner HTTP
/// `Host`, which is exactly what domain fronting needs. The 216.239.3x.120 set
/// fronts arbitrary Google-owned Hosts reliably; most other Google IPs do not.
/// Verified on the wire: SNI `www.google.com` + Host `www.gstatic.com` +
/// `/generate_204` returns 204 through these, and Host `script.google.com`
/// (Apps Script) is routed too.
const List<String> kGoogleFrontIps = <String>[
  '216.239.38.120',
  '216.239.32.120',
  '216.239.34.120',
  '216.239.36.120',
];

/// The default SNI to present to the front edge. `www.google.com` is never
/// blocked (blocking it breaks Google entirely), so a DPI box sees only a
/// connection to www.google.com and cannot read the real Host inside the TLS.
const String kDefaultFrontSni = 'www.google.com';

/// A tiny always-up Google-owned probe used to prove the front path end to end.
/// It answers 204 with an empty body, so a 204 means "the fronted edge reached
/// a Google backend by Host" without depending on the relay at all.
const String kFrontProbeUrl = 'https://www.gstatic.com/generate_204';

/// Builds an [http.Client] that domain-fronts every request through a CDN edge.
///
/// The TCP dial goes to [edgeIp]; the TLS SNI (and certificate validation) use
/// [frontSni]; but the HTTP request keeps its own real `Host` header. A
/// multi-tenant edge (Google GFE, Cloudflare, Fastly, ...) then routes by that
/// inner Host to the true destination. To a DPI box the handshake looks like an
/// ordinary connection to [frontSni] and the real target is invisible.
///
/// This mirrors [buildSecureClient] (custom dial + explicit SNI via
/// `SecureSocket.secure`), but here the SNI is deliberately a *different* host
/// than the request URL. That is the whole point of fronting: request
/// `https://script.google.com/.../exec`, dial a Google edge, hand-shake as
/// `www.google.com`, and let Google's frontend deliver it to Apps Script.
///
/// A wrong/stale [edgeIp] fails closed on the TLS handshake (the edge either
/// does not answer or presents a cert that does not cover [frontSni]) rather
/// than silently talking to the wrong server.
http.Client buildFrontedClient({
  required String frontSni,
  required String edgeIp,
}) {
  final HttpClient inner = HttpClient();
  inner.connectionFactory =
      (Uri uri, String? proxyHost, int? proxyPort) async {
    final int port =
        uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    // Proxies are never used on the fronted path; ignore proxyHost.
    final ConnectionTask<Socket> raw = await Socket.startConnect(edgeIp, port);
    if (uri.scheme != 'https') return raw;
    final Future<SecureSocket> secured = raw.socket.then((Socket sock) {
      // Low-latency: the fronted path is already one extra hop.
      sock.setOption(SocketOption.tcpNoDelay, true);
      return SecureSocket.secure(sock, host: frontSni);
    });
    return ConnectionTask.fromSocket(secured, raw.cancel);
  };
  return io.IOClient(inner);
}

/// Fronts the [kFrontProbeUrl] through ([frontSni], [edgeIp]) and returns the
/// HTTP status. Throws on any transport failure. A 204 proves the front works.
Future<int> frontProbe({
  required String frontSni,
  required String edgeIp,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final http.Client c = buildFrontedClient(frontSni: frontSni, edgeIp: edgeIp);
  try {
    final http.Response r =
        await c.get(Uri.parse(kFrontProbeUrl)).timeout(timeout);
    return r.statusCode;
  } finally {
    c.close();
  }
}

/// Races the [kGoogleFrontIps] pool (fronting the probe on each) and returns the
/// first IP that answers 2xx, or null if none do. Lets the app auto-pick a live
/// front edge instead of hard-coding one, since any single anycast IP can be
/// unreachable from a given network.
Future<String?> pickFrontIp({
  String frontSni = kDefaultFrontSni,
  List<String> pool = kGoogleFrontIps,
  Duration perIp = const Duration(seconds: 6),
}) async {
  final Completer<String?> done = Completer<String?>();
  int pending = pool.length;
  for (final String ip in pool) {
    frontProbe(frontSni: frontSni, edgeIp: ip, timeout: perIp).then((int code) {
      if (code >= 200 && code < 400 && !done.isCompleted) {
        done.complete(ip);
      }
    }).whenComplete(() {
      pending--;
      if (pending == 0 && !done.isCompleted) done.complete(null);
    });
  }
  return done.future;
}
