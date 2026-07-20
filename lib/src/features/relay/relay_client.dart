import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// An [http.Client] that tunnels every request through a Google Apps Script
/// relay (the "Google relay" the panel sets up). To an ISP the traffic looks
/// like `script.google.com`, and the Apps Script forwards the fetch to the Nova
/// Cloudflare worker exit, which fetches the real target and returns the body.
///
/// This makes the CONTROL plane (subscription import/refresh, the /admin API)
/// reachable even when the panel's own domain (for example Cloudflare) is
/// blocked, because the device only ever talks to Google. It does NOT carry the
/// VPN tunnel itself (Apps Script has no WebSocket/TCP/UDP); see the in-app guide.
///
/// Wire protocol (matches worker.js handleRelayRequest):
///   `POST execUrl { u, m, h, b(base64), r, k? }` returns `{ s, h, b(base64) }` or `{ e }`
/// The auth key `k` is usually baked into the Apps Script, so it is optional
/// here; include it when talking straight to the worker's /relay endpoint.
class RelayClient extends http.BaseClient {
  RelayClient({required this.execUrl, this.authKey, http.Client? inner})
      : _inner = inner ?? http.Client();

  /// The Apps Script `/exec` URL (or the worker `/relay` URL).
  final String execUrl;

  /// Optional relay auth key (only needed when the front does not inject it).
  final String? authKey;

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List body = await request.finalize().toBytes();
    final Map<String, dynamic> envelope = <String, dynamic>{
      'u': request.url.toString(),
      'm': request.method.toUpperCase(),
      'h': <String, String>{
        for (final MapEntry<String, String> e in request.headers.entries)
          if (!_skip.contains(e.key.toLowerCase())) e.key: e.value,
      },
      'r': request.followRedirects,
      if (body.isNotEmpty) 'b': base64.encode(body),
      if (authKey != null && authKey!.isNotEmpty) 'k': authKey,
    };

    final http.Response relayed = await _inner.post(
      Uri.parse(execUrl),
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(envelope),
    );

    // The relay itself failed (Google/worker unreachable, not configured, ...).
    if (relayed.statusCode >= 400) {
      throw RelayException('relay returned HTTP ${relayed.statusCode}');
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(relayed.body) as Map<String, dynamic>;
    } catch (_) {
      throw RelayException('relay sent a non-JSON reply');
    }
    if (j['e'] != null) throw RelayException(j['e'].toString());

    final int status = (j['s'] as num?)?.toInt() ?? 502;
    final Map<String, String> headers = <String, String>{};
    if (j['h'] is Map) {
      (j['h'] as Map<dynamic, dynamic>).forEach((dynamic k, dynamic v) {
        headers[k.toString().toLowerCase()] = v.toString();
      });
    }
    final List<int> respBody =
        (j['b'] is String && (j['b'] as String).isNotEmpty) ? base64.decode(j['b'] as String) : <int>[];
    // Content-Length from the front is for its own transfer; drop it so the
    // reconstructed response length matches the decoded body.
    headers.remove('content-length');
    headers.remove('content-encoding');
    headers.remove('transfer-encoding');

    return http.StreamedResponse(
      Stream<List<int>>.value(respBody),
      status,
      contentLength: respBody.length,
      request: request,
      headers: headers,
      reasonPhrase: null,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }

  // Hop-by-hop / auto headers the relay/worker sets or rejects.
  static const Set<String> _skip = <String>{
    'host', 'connection', 'content-length', 'transfer-encoding',
    'proxy-connection', 'proxy-authorization',
  };
}

class RelayException implements Exception {
  RelayException(this.message);
  final String message;
  @override
  String toString() => 'RelayException: $message';
}
