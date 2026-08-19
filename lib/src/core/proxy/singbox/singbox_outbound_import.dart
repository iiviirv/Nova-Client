import 'dart:convert';

import 'proxy_node.dart';

/// Turns a sing-box configuration document (or a bare `outbounds` list) into
/// [ProxyNode]s.
///
/// Why this exists: the Nova panel's own subscription target,
/// `sub?...&target=nova`, does not return a list of share links. It returns a
/// ready-made sing-box config, `{"outbounds": [ {...}, ... ]}`. The client's
/// subscription parser only understood share links, so a Nova-target
/// subscription imported fine (the URL was saved) but yielded zero servers, and
/// only worked once the user stripped `&target=nova` by hand. That is the exact
/// report from the field, on Android and on macOS.
///
/// This is the inverse of the config builder in `singbox_config.dart`: field
/// names here mirror what that emits (`server_name`, `insecure`, `utls`,
/// `reality.public_key`, `transport.path`, ...), so a node round-trips.
///
/// Group / plumbing outbounds (`selector`, `urltest`, `direct`, `block`, `dns`)
/// are not servers and are skipped. Anything unrecognised is skipped, never
/// guessed at.
List<ProxyNode> parseSingboxOutbounds(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const <ProxyNode>[];
  }
  final List<dynamic> outbounds;
  if (decoded is Map && decoded['outbounds'] is List) {
    outbounds = decoded['outbounds'] as List<dynamic>;
  } else if (decoded is List) {
    outbounds = decoded;
  } else {
    return const <ProxyNode>[];
  }
  final List<ProxyNode> nodes = <ProxyNode>[];
  for (final Object? raw in outbounds) {
    if (raw is! Map) continue;
    final ProxyNode? n = _outboundToNode(raw.cast<String, dynamic>());
    if (n != null) nodes.add(n);
  }
  return nodes;
}

/// True when [body] looks like a sing-box document rather than a share-link
/// list: cheap enough to run on every subscription body before the line
/// parser.
bool looksLikeSingboxConfig(String body) {
  final String t = body.trimLeft();
  if (!t.startsWith('{') && !t.startsWith('[')) return false;
  return t.contains('"outbounds"') || t.contains('"type"');
}

ProxyNode? _outboundToNode(Map<String, dynamic> o) {
  final String type = (o['type'] as String? ?? '').toLowerCase();
  final NodeProtocol? protocol = _protocolFor(type);
  if (protocol == null) return null;

  final String? server = o['server'] as String?;
  final int? port = (o['server_port'] as num?)?.toInt();
  if (server == null || server.isEmpty || port == null) return null;

  final Map<String, dynamic> tls =
      (o['tls'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final bool tlsOn = tls['enabled'] == true;
  final Map<String, dynamic> utls =
      (tls['utls'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final Map<String, dynamic> reality =
      (tls['reality'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
  final bool realityOn = reality['enabled'] == true;

  final Map<String, dynamic> transport =
      (o['transport'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
  final String network = (transport['type'] as String? ?? 'tcp').toLowerCase();
  final Map<String, dynamic> headers =
      (transport['headers'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};

  final Map<String, dynamic> obfs =
      (o['obfs'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};

  final List<String> alpn = <String>[
    for (final Object? a in (tls['alpn'] as List<dynamic>?) ?? const <dynamic>[])
      if (a is String) a,
  ];

  return ProxyNode(
    protocol: protocol,
    server: server,
    port: port,
    tag: (o['tag'] as String?)?.trim().isNotEmpty == true
        ? (o['tag'] as String).trim()
        : '$server:$port',
    uuid: o['uuid'] as String?,
    // Trojan/SS/Hysteria2/TUIC/mieru all carry the secret as `password`.
    password: o['password'] as String?,
    method: o['method'] as String?,
    tls: tlsOn,
    sni: tls['server_name'] as String?,
    allowInsecure: tls['insecure'] == true,
    alpn: alpn,
    fingerprint: utls['fingerprint'] as String?,
    flow: o['flow'] as String?,
    network: network,
    // ws / httpupgrade / http share `path`; ws also carries a Host header.
    wsPath: transport['path'] as String?,
    wsHost: (headers['Host'] ?? headers['host']) as String?,
    grpcServiceName: transport['service_name'] as String?,
    realityPublicKey: realityOn ? reality['public_key'] as String? : null,
    realityShortId: realityOn ? reality['short_id'] as String? : null,
    vmessAlterId: (o['alter_id'] as num?)?.toInt() ?? 0,
    vmessSecurity: o['security'] as String?,
    obfsType: obfs['type'] as String?,
    obfsPassword: obfs['password'] as String?,
    congestionControl: o['congestion_control'] as String?,
    udpRelayMode: o['udp_relay_mode'] as String?,
    hy2UpMbps: (o['up_mbps'] as num?)?.toInt(),
    hy2DownMbps: (o['down_mbps'] as num?)?.toInt(),
    mieruTransport: (o['transport'] is String)
        ? (o['transport'] as String).toUpperCase()
        : 'TCP',
    mieruMultiplexing: o['multiplexing'] as String? ?? 'MULTIPLEXING_LOW',
  );
}

NodeProtocol? _protocolFor(String type) => switch (type) {
      'vless' => NodeProtocol.vless,
      'vmess' => NodeProtocol.vmess,
      'trojan' => NodeProtocol.trojan,
      'shadowsocks' => NodeProtocol.shadowsocks,
      'hysteria2' => NodeProtocol.hysteria2,
      'tuic' => NodeProtocol.tuic,
      'socks' => NodeProtocol.socks,
      'http' => NodeProtocol.http,
      'naive' => NodeProtocol.naive,
      'mieru' => NodeProtocol.mieru,
      // selector / urltest / direct / block / dns are not servers.
      _ => null,
    };
