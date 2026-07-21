import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An [http.Client] that accepts self-signed / untrusted TLS certificates.
///
/// This is used ONLY for the "no domain" VPS case, where the Nova node agent
/// terminates TLS with a self-signed certificate (there is no Cloudflare in
/// front to present a real one). The user opts into this explicitly with the
/// "My server has no domain" switch; for a real domain we use the default
/// validating client instead.
///
/// The tunnel itself already carries `allowInsecure=1` for the same case, so
/// the control-plane (this client) and the data-plane stay consistent.
http.Client buildInsecureClient() {
  final HttpClient io = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) =>
        true;
  return IOClient(io);
}
