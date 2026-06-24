/// A single proxy node parsed from a share link (vless://, trojan://, ss://).
///
/// This is the protocol-agnostic intermediate representation the sing-box
/// config builder turns into an outbound. It mirrors the fields Nova Proxy
/// emits (VLESS / Trojan / Shadowsocks over WS/gRPC + TLS).
enum NodeProtocol { vless, trojan, shadowsocks }

extension NodeProtocolName on NodeProtocol {
  /// The sing-box outbound `type` for this protocol.
  String get singboxType => switch (this) {
        NodeProtocol.vless => 'vless',
        NodeProtocol.trojan => 'trojan',
        NodeProtocol.shadowsocks => 'shadowsocks',
      };
}

class ProxyNode {
  ProxyNode({
    required this.protocol,
    required this.server,
    required this.port,
    this.tag = 'proxy',
    this.uuid,
    this.password,
    this.method,
    this.tls = false,
    this.sni,
    this.allowInsecure = false,
    this.alpn = const <String>[],
    this.fingerprint,
    this.flow,
    this.network = 'tcp',
    this.wsPath,
    this.wsHost,
    this.grpcServiceName,
  });

  final NodeProtocol protocol;
  final String server;
  final int port;

  /// Display name (from the link fragment).
  final String tag;

  // Auth — protocol-specific.
  final String? uuid; // vless
  final String? password; // trojan / shadowsocks
  final String? method; // shadowsocks cipher

  // TLS.
  final bool tls;
  final String? sni;
  final bool allowInsecure;
  final List<String> alpn;
  final String? fingerprint; // uTLS fingerprint (e.g. "chrome")
  final String? flow; // vless flow (e.g. xtls-rprx-vision)

  // Transport.
  final String network; // tcp | ws | grpc | http
  final String? wsPath;
  final String? wsHost;
  final String? grpcServiceName;

  bool get hasTls => tls;

  /// Returns a copy with selected fields overridden. Used to stamp a Radar
  /// clean IP into a subscription template node: keep every protocol/transport
  /// field and only swap the address, port, and display name.
  ProxyNode copyWith({
    String? server,
    int? port,
    String? tag,
    String? sni,
    String? wsHost,
  }) {
    return ProxyNode(
      protocol: protocol,
      server: server ?? this.server,
      port: port ?? this.port,
      tag: tag ?? this.tag,
      uuid: uuid,
      password: password,
      method: method,
      tls: tls,
      sni: sni ?? this.sni,
      allowInsecure: allowInsecure,
      alpn: alpn,
      fingerprint: fingerprint,
      flow: flow,
      network: network,
      wsPath: wsPath,
      wsHost: wsHost ?? this.wsHost,
      grpcServiceName: grpcServiceName,
    );
  }
}
