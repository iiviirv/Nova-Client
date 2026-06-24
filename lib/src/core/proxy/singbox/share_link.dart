import 'dart:convert';

import 'proxy_node.dart';

/// Parses a proxy share link into a [ProxyNode].
///
/// Supports the formats Nova Proxy hands out:
///   * `vless://uuid@host:port?security=tls&type=ws&path=/..&host=..&sni=..#name`
///   * `trojan://password@host:port?security=tls&type=ws&path=..#name`
///   * `ss://base64(method:password)@host:port#name`  (SIP002)
///   * `ss://base64(method:password@host:port)#name`  (legacy)
///
/// Returns `null` for unsupported schemes or malformed links rather than
/// throwing, so callers can surface a friendly error.
ProxyNode? parseShareLink(String raw) {
  final String input = raw.trim();
  if (input.isEmpty) return null;

  final int schemeEnd = input.indexOf('://');
  if (schemeEnd < 0) return null;
  final String scheme = input.substring(0, schemeEnd).toLowerCase();

  try {
    return switch (scheme) {
      'vless' => _parseUserInfoLink(input, NodeProtocol.vless),
      'trojan' => _parseUserInfoLink(input, NodeProtocol.trojan),
      'ss' => _parseShadowsocks(input),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// VLESS and Trojan share the same `scheme://credential@host:port?params#name`
/// shape; only the credential field differs (uuid vs password).
ProxyNode? _parseUserInfoLink(String input, NodeProtocol protocol) {
  final Uri uri = Uri.parse(input);
  final String host = uri.host;
  final int port = uri.port;
  if (host.isEmpty || port == 0) return null;

  final String credential = Uri.decodeComponent(uri.userInfo);
  if (credential.isEmpty) return null;

  final Map<String, String> q = uri.queryParameters;
  final String security = (q['security'] ?? '').toLowerCase();
  final bool tls = security == 'tls' || security == 'reality' || security == 'xtls';
  final String network = _normalizeNetwork(q['type'] ?? 'tcp');

  return ProxyNode(
    protocol: protocol,
    server: host,
    port: port,
    tag: _name(uri, host),
    uuid: protocol == NodeProtocol.vless ? credential : null,
    password: protocol == NodeProtocol.trojan ? credential : null,
    tls: tls,
    sni: q['sni'] ?? q['peer'] ?? (tls ? host : null),
    allowInsecure: q['allowInsecure'] == '1' || q['allow_insecure'] == 'true',
    alpn: _splitAlpn(q['alpn']),
    fingerprint: q['fp'],
    flow: (q['flow'] ?? '').isEmpty ? null : q['flow'],
    network: network,
    wsPath: network == 'ws' ? (q['path'] ?? '/') : null,
    wsHost: network == 'ws' ? (q['host'] ?? q['sni']) : null,
    grpcServiceName: network == 'grpc' ? (q['serviceName'] ?? q['path'] ?? '') : null,
  );
}

ProxyNode? _parseShadowsocks(String input) {
  // Strip scheme and fragment.
  final int hashIndex = input.indexOf('#');
  final String name = hashIndex >= 0
      ? Uri.decodeComponent(input.substring(hashIndex + 1))
      : '';
  final String body =
      (hashIndex >= 0 ? input.substring(0, hashIndex) : input).substring(5);

  String method;
  String password;
  String host;
  int port;

  final int atIndex = body.lastIndexOf('@');
  if (atIndex >= 0) {
    // SIP002: ss://base64(method:password)@host:port
    final String userPart = body.substring(0, atIndex);
    final String hostPart = body.substring(atIndex + 1);
    final String decoded = _looksBase64(userPart)
        ? _decodeBase64(userPart)
        : Uri.decodeComponent(userPart);
    final int colon = decoded.indexOf(':');
    if (colon < 0) return null;
    method = decoded.substring(0, colon);
    password = decoded.substring(colon + 1);
    final (String h, int p) = _splitHostPort(hostPart);
    host = h;
    port = p;
  } else {
    // Legacy: ss://base64(method:password@host:port)
    final String decoded = _decodeBase64(body);
    final int at = decoded.lastIndexOf('@');
    if (at < 0) return null;
    final int colon = decoded.indexOf(':');
    if (colon < 0 || colon > at) return null;
    method = decoded.substring(0, colon);
    password = decoded.substring(colon + 1, at);
    final (String h, int p) = _splitHostPort(decoded.substring(at + 1));
    host = h;
    port = p;
  }

  if (host.isEmpty || port == 0) return null;
  return ProxyNode(
    protocol: NodeProtocol.shadowsocks,
    server: host,
    port: port,
    tag: name.isEmpty ? host : name,
    method: method,
    password: password,
  );
}

String _name(Uri uri, String fallback) {
  final String fragment = uri.fragment;
  if (fragment.isEmpty) return fallback;
  return Uri.decodeComponent(fragment);
}

(String, int) _splitHostPort(String hostPort) {
  // Drop any trailing query/path the host:port might carry.
  String hp = hostPort;
  final int slash = hp.indexOf('/');
  if (slash >= 0) hp = hp.substring(0, slash);
  final int q = hp.indexOf('?');
  if (q >= 0) hp = hp.substring(0, q);
  final int colon = hp.lastIndexOf(':');
  if (colon < 0) return (hp, 0);
  final int port = int.tryParse(hp.substring(colon + 1)) ?? 0;
  return (hp.substring(0, colon), port);
}

String _normalizeNetwork(String type) {
  final String t = type.toLowerCase();
  return switch (t) {
    'ws' || 'websocket' => 'ws',
    'grpc' => 'grpc',
    'http' || 'h2' => 'http',
    _ => 'tcp',
  };
}

List<String> _splitAlpn(String? alpn) {
  if (alpn == null || alpn.isEmpty) return const <String>[];
  return alpn
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

bool _looksBase64(String s) {
  // SIP002 userinfo is base64; a raw "method:password" contains a colon.
  return !s.contains(':');
}

/// Decodes standard or URL-safe base64, tolerating missing padding.
String _decodeBase64(String input) {
  String s = input.replaceAll('-', '+').replaceAll('_', '/');
  final int mod = s.length % 4;
  if (mod != 0) s = s.padRight(s.length + (4 - mod), '=');
  return utf8.decode(base64.decode(s));
}
