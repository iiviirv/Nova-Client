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
}
