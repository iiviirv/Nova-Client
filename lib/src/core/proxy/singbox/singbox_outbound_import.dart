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
  // sing-box 1.11 moved WireGuard and AmneziaWG out of `outbounds` into their
  // own `endpoints` array. Reading only `outbounds` meant a Nova-target
  // subscription carrying an AmneziaWG node imported it as nothing: pasting the
  // awg:// link by hand worked, the same server delivered by subscription
  // silently vanished, and nothing said so.
  if (decoded is Map && decoded['endpoints'] is List) {
    for (final Object? raw in decoded['endpoints'] as List<dynamic>) {
      if (raw is! Map) continue;
      final ProxyNode? n = _endpointToNode(raw.cast<String, dynamic>());
      if (n != null) nodes.add(n);
    }
  }
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

/// A sing-box `endpoints[]` entry back into a node.
///
/// The inverse of AwgConfig.toEndpoint. Only WireGuard and AmneziaWG live here;
/// anything else in the array is left alone.
ProxyNode? _endpointToNode(Map<String, dynamic> e) {
  final String type = (e['type'] as String? ?? '').toLowerCase();
  if (type != 'wireguard' && type != 'awg' && type != 'amnezia') return null;
  final List<dynamic> peers = (e['peers'] as List<dynamic>?) ?? <dynamic>[];
  if (peers.isEmpty || peers.first is! Map) return null;
  final Map<String, dynamic> peer =
      (peers.first as Map).cast<String, dynamic>();
  final String host = (peer['address'] as String? ?? '').trim();
  final int port = (peer['port'] as num?)?.toInt() ?? 0;
  if (host.isEmpty || port <= 0) return null;

  // Rebuild the .conf text the rest of the app already understands rather than
  // inventing a second representation of the same node. AwgConfig.parseConf is
  // what SingboxConfig calls to write this endpoint back out, so a round trip
  // through here lands on the JSON it came from.
  String list(Object? v) => v is List ? v.join(', ') : (v?.toString() ?? '');
  final StringBuffer b = StringBuffer()
    ..writeln('[Interface]')
    ..writeln('PrivateKey = ${e['private_key'] ?? ''}')
    ..writeln('Address = ${list(e['address'])}');
  if (e['mtu'] != null) b.writeln('MTU = ${e['mtu']}');
  for (final String k in const <String>[
    'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4',
    'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5',
  ]) {
    if (e[k] != null) b.writeln('${k.toUpperCase()} = ${e[k]}');
  }
  b
    ..writeln('[Peer]')
    ..writeln('PublicKey = ${peer['public_key'] ?? ''}')
    ..writeln('Endpoint = $host:$port')
    ..writeln('AllowedIPs = ${list(peer['allowed_ips'])}');
  final Object? psk = peer['preshared_key'] ?? peer['pre_shared_key'];
  if (psk != null) b.writeln('PresharedKey = $psk');
  final Object? ka = peer['persistent_keepalive_interval'];
  if (ka != null) b.writeln('PersistentKeepalive = $ka');

  final String tag = (e['tag'] as String? ?? '').trim();
  return ProxyNode(
    protocol: NodeProtocol.awg,
    tag: tag.isNotEmpty ? tag : '$host:$port',
    server: host,
    port: port,
    awgConf: b.toString(),
  );
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

  // socks / http / naive / mieru carry their username in the uuid slot (that
  // is how ProxyNode models them, and how the config builder emits them
  // back as `username`). vless/vmess use a real `uuid`.
  final String? uuid = (o['uuid'] as String?) ?? (o['username'] as String?);

  // mieru: the panel emits `portBindings: [{port, protocol}]`; the protocol
  // there is the transport (TCP/UDP). Fall back to a top-level string
  // `transport` if that is what a config carries instead.
  String mieruTransport = 'TCP';
  final List<dynamic>? bindings = o['portBindings'] as List<dynamic>?;
  if (bindings != null && bindings.isNotEmpty && bindings.first is Map) {
    final String? proto =
        ((bindings.first as Map)['protocol'] as String?)?.toUpperCase();
    if (proto == 'UDP') mieruTransport = 'UDP';
  } else if (o['transport'] is String) {
    if ((o['transport'] as String).toUpperCase() == 'UDP') {
      mieruTransport = 'UDP';
    }
  }

  return ProxyNode(
    protocol: protocol,
    server: server,
    port: port,
    tag: (o['tag'] as String?)?.trim().isNotEmpty == true
        ? (o['tag'] as String).trim()
        : '$server:$port',
    uuid: uuid,
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
    mieruTransport: mieruTransport,
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
