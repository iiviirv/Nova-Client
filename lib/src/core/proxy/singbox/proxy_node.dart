import 'dart:io' show InternetAddress;

import 'awg_config.dart';

/// A single proxy node parsed from a share link.
///
/// This is the protocol-agnostic intermediate representation the sing-box
/// config builder turns into an outbound. Nova Proxy's own nodes are VLESS /
/// Trojan / Shadowsocks over WS/gRPC + TLS, but the bundled sing-box core also
/// runs VMess, Hysteria2, TUIC and VLESS-Reality — used when a subscription
/// points at a real server (not just the Cloudflare Worker), which is the path
/// to real UDP/QUIC and higher speed. AmneziaWG (`awg`) is a WireGuard endpoint
/// with junk-packet obfuscation, so it is carried as a sing-box endpoint, not an
/// outbound; see [awgConf] and [SingboxConfig].
enum NodeProtocol {
  vless,
  trojan,
  shadowsocks,
  vmess,
  hysteria2,
  tuic,
  awg,
  socks,
  http,

  /// NaiveProxy: HTTP/2 CONNECT inside TLS, with padding that makes the
  /// request/response sizes look like ordinary browsing. Nova Server has always
  /// been able to create a Naive inbound, and the mobile cores are built with
  /// `with_naive_outbound`, but the app could not read the `naive+https://`
  /// link, so an operator who made one watched it appear in no client at all.
  naive,
}

extension NodeProtocolName on NodeProtocol {
  /// The sing-box outbound (or endpoint) `type` for this protocol.
  String get singboxType => switch (this) {
        NodeProtocol.vless => 'vless',
        NodeProtocol.trojan => 'trojan',
        NodeProtocol.shadowsocks => 'shadowsocks',
        NodeProtocol.vmess => 'vmess',
        NodeProtocol.hysteria2 => 'hysteria2',
        NodeProtocol.tuic => 'tuic',
        NodeProtocol.awg => 'awg',
        NodeProtocol.socks => 'socks',
        NodeProtocol.http => 'http',
        NodeProtocol.naive => 'naive',
      };

  /// UDP-native protocols (QUIC / WireGuard). These carry UDP end to end, so
  /// unlike the TCP-only worker exit they don't need QUIC blocked.
  bool get isUdpNative =>
      this == NodeProtocol.hysteria2 ||
      this == NodeProtocol.tuic ||
      this == NodeProtocol.awg;

  /// AmneziaWG / WireGuard is a sing-box `endpoint`, not an `outbound`.
  bool get isEndpoint => this == NodeProtocol.awg;

  String get label => switch (this) {
        NodeProtocol.vless => 'VLESS',
        NodeProtocol.trojan => 'Trojan',
        NodeProtocol.shadowsocks => 'Shadowsocks',
        NodeProtocol.vmess => 'VMess',
        NodeProtocol.hysteria2 => 'Hysteria2',
        NodeProtocol.tuic => 'TUIC',
        NodeProtocol.awg => 'AmneziaWG',
        NodeProtocol.socks => 'SOCKS',
        NodeProtocol.http => 'HTTP',
        NodeProtocol.naive => 'NaiveProxy',
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
    this.realityPublicKey,
    this.realityShortId,
    this.vmessAlterId = 0,
    this.vmessSecurity,
    this.obfsType,
    this.obfsPassword,
    this.congestionControl,
    this.udpRelayMode,
    this.hy2UpMbps,
    this.hy2DownMbps,
    this.awgConf,
    this.cipherSuites = const <String>[],
    this.fragmentMask,
  });

  /// Build an AmneziaWG node from a raw `awg-quick` `.conf`. The peer endpoint
  /// becomes [server]:[port] (so pinning, dedup, and clean-domain seeding work
  /// like any other node); the full config text is kept in [awgConf] and parsed
  /// into the sing-box `awg` endpoint at build time.
  factory ProxyNode.fromAwgConf(String conf, {String? name}) {
    final AwgConfig c = AwgConfig.parseConf(conf);
    final String dflt = c.isObfuscated ? 'AmneziaWG' : 'WireGuard';
    return ProxyNode(
      protocol: NodeProtocol.awg,
      server: c.peer.host,
      port: c.peer.port,
      tag: (name == null || name.trim().isEmpty) ? dflt : name.trim(),
      awgConf: conf,
    );
  }

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

  // VLESS-Reality (server_name is [sni]; these add the reality handshake).
  final String? realityPublicKey; // reality "pbk"
  final String? realityShortId; // reality "sid"

  // VMess.
  final int vmessAlterId; // "aid" (0 for AEAD)
  final String?
      vmessSecurity; // "scy": auto | aes-128-gcm | chacha20-poly1305 | none

  // Hysteria2 (QUIC). Auth uses [password]; salamander obfuscation is optional.
  final String? obfsType; // "salamander" when set
  final String? obfsPassword;

  // Hysteria2 bandwidth hints (Mbps). When set, sing-box uses the Brutal
  // congestion controller (fixed-rate, ignores loss) instead of BBR, which is
  // the big throughput win on loss-throttled links. Absent => BBR (safe default).
  final int? hy2UpMbps;
  final int? hy2DownMbps;

  // TUIC (QUIC). Auth uses [uuid] + [password].
  final String? congestionControl; // "bbr" | "cubic" | "new_reno"
  final String? udpRelayMode; // "native" | "quic"

  // AmneziaWG / WireGuard: the raw `.conf` text. Parsed to a sing-box `awg`
  // endpoint (keys, address, peer, and the junk params) at config-build time.
  final String? awgConf;

  // The SNI-block bypass profile, as PattNG-style links carry it (`cs=` and
  // `fm=`, with `fp=unsafe`). See [isHardenedTls]. [cipherSuites] is the TLS 1.2
  // cipher list in preference order; [fragmentMask] is the raw Xray finalmask
  // JSON, kept verbatim so a link can be re-shared unchanged. The sing-box core
  // has no per-segment lengths or delays, so the mask's presence selects its
  // TLS-record and TCP-segment fragmentation rather than reproducing the exact
  // sizes.
  final List<String> cipherSuites;
  final String? fragmentMask;

  bool get isReality =>
      (realityPublicKey != null && realityPublicKey!.isNotEmpty);

  /// True when the link asked for the SNI-block bypass profile: `fp=unsafe` in
  /// Xray terms means "no browser fingerprint, Go's own TLS with my cipher
  /// list", and it travels with a fragment mask. Nova treats either signal as
  /// the request, since a link from cf-optimizor carries all three.
  bool get isHardenedTls =>
      fingerprint == 'unsafe' ||
      cipherSuites.isNotEmpty ||
      (fragmentMask != null && fragmentMask!.isNotEmpty);

  /// The node is a Cloudflare-fronted worker reached through a clean IP: the
  /// address is an IP literal and the TLS name (SNI or Host) is a real domain.
  /// These are the nodes the SNI-block bypass is for. A domain-addressed node
  /// is left alone, which is what the operators asked for.
  bool get isCleanIpFronted {
    if (!tls) return false;
    if (InternetAddress.tryParse(server) == null) return false;
    final String name = (sni ?? wsHost ?? '').trim();
    return name.isNotEmpty && name != server;
  }

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
    List<String>? cipherSuites,
    String? fragmentMask,
    String? fingerprint,
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
      flow: flow,
      network: network,
      wsPath: wsPath,
      wsHost: wsHost ?? this.wsHost,
      grpcServiceName: grpcServiceName,
      realityPublicKey: realityPublicKey,
      realityShortId: realityShortId,
      vmessAlterId: vmessAlterId,
      vmessSecurity: vmessSecurity,
      obfsType: obfsType,
      obfsPassword: obfsPassword,
      congestionControl: congestionControl,
      udpRelayMode: udpRelayMode,
      hy2UpMbps: hy2UpMbps,
      hy2DownMbps: hy2DownMbps,
      awgConf: awgConf,
      cipherSuites: cipherSuites ?? this.cipherSuites,
      fragmentMask: fragmentMask ?? this.fragmentMask,
      fingerprint: fingerprint ?? this.fingerprint,
    );
  }

  /// This node with the SNI-block bypass profile applied: Go's own TLS instead
  /// of a browser fingerprint (`unsafe`), the cipher list PattNG uses, and a
  /// fragment mask. Idempotent, and it never touches a node that already
  /// carries its own hardening from the link.
  ProxyNode hardened() {
    if (isHardenedTls) return this;
    return copyWith(
      fingerprint: 'unsafe',
      cipherSuites: kBypassCipherSuites,
      fragmentMask: kBypassFragmentMask,
    );
  }
}

/// The cipher list the field-tested PattNG recipe sends, in its order. TLS 1.3
/// suites first (Go fixes their order regardless), then ECDHE GCM and ChaCha,
/// then the two CBC-SHA suites Go still ships as secure. The recipe also lists
/// TLS_ECDHE_ECDSA/RSA_WITH_AES_128_CBC_SHA256; the sing-box core refuses those
/// two ("unknown cipher_suite", they are in Go's insecure set), so they are not
/// here. That is the one place this ClientHello differs from PattNG's.
const List<String> kBypassCipherSuites = <String>[
  'TLS_AES_256_GCM_SHA384',
  'TLS_CHACHA20_POLY1305_SHA256',
  'TLS_AES_128_GCM_SHA256',
  'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
  'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
  'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
  'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
  'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256',
  'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256',
  'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA',
  'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA',
];

/// The Xray finalmask the field-tested recipe uses, kept verbatim so a hardened
/// node re-shares as a link PattNG accepts. Two stages: the ClientHello split
/// into TLS records of 5, 94, then 1 byte each (one TCP write), then that first
/// write split into TCP segments of 109 and then 1 byte with 1 ms between them.
const String kBypassFragmentMask =
    '{"tcp":[{"type":"fragment","settings":{"packets":"tlshello",'
    '"lengths":["5","94","1"],"delays":["0"],"maxSplit":"0"}},'
    '{"type":"fragment","settings":{"packets":"1-1","lengths":["109","1"],'
    '"delays":["1"],"maxSplit":"355"}}]}';

/// Stable identity for selecting and latency-ranking a node.
///
/// A subscription can expose several protocols or WebSocket paths on the same
/// address and port, so `server:port` alone is ambiguous.
String proxyNodeKey(ProxyNode node) =>
    '${node.server}:${node.port}:${node.protocol.name}:${node.wsPath ?? ''}';

/// Accept the full key used by current builds and the old `server:port` key
/// already persisted by earlier releases.
bool proxyNodeMatchesKey(ProxyNode node, String key) =>
    key == proxyNodeKey(node) || key == '${node.server}:${node.port}';
