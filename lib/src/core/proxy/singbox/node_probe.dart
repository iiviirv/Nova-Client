import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'proxy_node.dart';

/// How much a probe actually proved about a node.
///
/// The distinction is the whole point of this file. Nova used to measure a bare
/// TCP connect and print it as a ping, which is a lie for the nodes our users
/// actually have: Cloudflare's anycast edge completes a TCP handshake for every
/// address in its range, so a worker node whose SNI is DPI-blocked, or whose
/// server IP is filtered the moment real data moves, showed a healthy green
/// number next to a config that could never carry a byte. A number the user
/// cannot act on is worse than no number, so a probe now says what it proved.
enum NodeProbeQuality {
  /// A real request travelled through the node to a host on the internet and
  /// came back. This is the only tier that proves the config *works*.
  proxied,

  /// The node's own server answered a protocol-level handshake (a WebSocket
  /// upgrade, an HTTP/2 settings exchange, a SOCKS greeting, a QUIC reply). The
  /// server is genuinely there and reachable through the censor; whether it
  /// will carry traffic for these credentials is unproven.
  handshake,

  /// Nothing answered: connection refused, reset, or timed out.
  unreachable,

  /// The node cannot be proven from outside a tunnel, so no number is shown.
  /// VLESS-Reality is indistinguishable from the site it fronts, an obfuscated
  /// Hysteria2 endpoint drops anything that isn't already obfuscated, and a
  /// WireGuard handshake needs the peer's keys. Guessing here is what produced
  /// the fake pings.
  untestable,
}

extension NodeProbeQualityInfo on NodeProbeQuality {
  /// Sort order for "best node first": proved > answered > unknown > dead.
  int get rank => switch (this) {
        NodeProbeQuality.proxied => 0,
        NodeProbeQuality.handshake => 1,
        NodeProbeQuality.untestable => 2,
        NodeProbeQuality.unreachable => 3,
      };

  /// Whether a latency is worth showing to the user.
  bool get carriesLatency =>
      this == NodeProbeQuality.proxied || this == NodeProbeQuality.handshake;
}

/// The outcome of probing one node.
class NodeProbeResult {
  const NodeProbeResult(this.quality, {this.latencyMs, this.reason});

  const NodeProbeResult.unreachable({this.reason})
      : quality = NodeProbeQuality.unreachable,
        latencyMs = null;

  const NodeProbeResult.untestable(this.reason)
      : quality = NodeProbeQuality.untestable,
        latencyMs = null;

  final NodeProbeQuality quality;

  /// Round-trip time in ms, set only when [quality] carries one.
  final int? latencyMs;

  /// Why a node is untestable or unreachable, for the row's detail line.
  final String? reason;

  bool get ok => quality.carriesLatency;

  /// Ranking key: quality first, then latency. Used to order the node list and
  /// to build the auto-select pool.
  int get sortKey => quality.rank * 1000000 + (latencyMs ?? 999999);
}

/// Measures what a node can actually be proven to do, from outside the tunnel.
///
/// Tiers are tried strongest-first and the result reports the strongest one that
/// held. A weaker tier is never reported as a failure of the stronger one: if a
/// WebSocket upgrade succeeds but the proxied request does not, that is
/// [NodeProbeQuality.handshake], because the server demonstrably answered.
///
/// [deep] runs the proxied tier (a real request through the node). It costs a
/// round trip to the open internet, so the pre-connect ranking inside the tunnel
/// controller leaves it off and only the user-facing node list turns it on.
Future<NodeProbeResult> probeNode(
  ProxyNode n, {
  Duration timeout = const Duration(seconds: 5),
  bool deep = true,
  bool bypass = false,
}) async {
  // When the SNI-block bypass is on for this profile, a clean-IP fronted node's
  // real handshake carries a fragmented ClientHello with a fixed cipher list
  // that only the core can produce. This probe uses the platform's own TLS,
  // which cannot, so on exactly the networks the bypass is for it would read
  // every such node as blocked while the tunnel connects fine. Say the probe
  // cannot judge it, rather than a false "blocked". The real proof is the
  // connect, which the controller's self-heal already handles.
  if (bypass && n.isCleanIpFronted) {
    return const NodeProbeResult.untestable(
        'SNI-block bypass on; tested when you connect');
  }
  try {
    return await _probe(n, timeout: timeout, deep: deep).timeout(
      timeout + const Duration(seconds: 2),
      onTimeout: () => const NodeProbeResult.unreachable(reason: 'timed out'),
    );
  } catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  }
}

Future<NodeProbeResult> _probe(
  ProxyNode n, {
  required Duration timeout,
  required bool deep,
}) async {
  switch (n.protocol) {
    case NodeProtocol.awg:
      // A WireGuard handshake initiation is authenticated with the peer's
      // static keys; without completing the noise handshake there is nothing
      // to measure, and a silent UDP endpoint is indistinguishable from a
      // blocked one.
      return const NodeProbeResult.untestable('WireGuard cannot be tested '
          'without connecting');

    case NodeProtocol.hysteria2:
    case NodeProtocol.tuic:
      if ((n.obfsType ?? '').isNotEmpty) {
        return const NodeProbeResult.untestable(
            'obfuscated QUIC only answers its own client');
      }
      return _probeQuic(n, timeout);

    case NodeProtocol.socks:
      return _probeSocks5(n, timeout, deep: deep);

    case NodeProtocol.http:
      return _probeHttpProxy(n, timeout, deep: deep);

    case NodeProtocol.naive:
      // Naive is HTTP/2 CONNECT inside TLS. The h2 settings exchange proves the
      // real server answered; driving CONNECT further would need the padding
      // scheme, which is not worth reimplementing for a measurement.
      return _probeNaive(n, timeout);

    case NodeProtocol.vless:
    case NodeProtocol.vmess:
    case NodeProtocol.trojan:
    case NodeProtocol.shadowsocks:
      return _probeStreamNode(n, timeout, deep: deep);
  }
}

Future<NodeProbeResult> _probeNaive(ProxyNode n, Duration timeout) async {
  final Stopwatch sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(n.server, n.port, timeout: timeout);
    final Socket stream = await _wrapTls(raw, n, timeout);
    final _Reader reader = _Reader(stream);
    try {
      if (!await _h2Settings(stream, reader, timeout)) {
        return const NodeProbeResult.unreachable(
            reason: 'no HTTP/2 response');
      }
      return NodeProbeResult(NodeProbeQuality.handshake,
          latencyMs: sw.elapsedMilliseconds);
    } finally {
      reader.cancel();
    }
  } on SocketException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on HandshakeException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on TimeoutException {
    return const NodeProbeResult.unreachable(reason: 'timed out');
  } finally {
    raw?.destroy();
  }
}

// ---------------------------------------------------------------------------
// Stream protocols (VLESS / VMess / Trojan / Shadowsocks over TCP, WS or gRPC)
// ---------------------------------------------------------------------------

Future<NodeProbeResult> _probeStreamNode(
  ProxyNode n,
  Duration timeout, {
  required bool deep,
}) async {
  if (n.isReality) {
    // Reality's whole design is that a handshake it does not authenticate is
    // forwarded to the real site it borrows the certificate from. A successful
    // TLS handshake therefore says nothing at all about the node.
    return const NodeProbeResult.untestable(
        'Reality is indistinguishable from the site it fronts');
  }
  final String transport = n.network.toLowerCase();
  if (transport == 'http') {
    // sing-box's `http` transport negotiates HTTP/1.1 or h2 depending on TLS
    // and wraps the stream differently in each case. Modelling that from outside
    // is guesswork, and a wrong guess reads as censorship, so say so up front
    // rather than spending a connection to arrive at the same answer.
    return const NodeProbeResult.untestable(
        'this transport cannot be tested without connecting');
  }
  if (transport == 'xhttp') {
    // xhttp (SplitHTTP) is an Xray-only transport; this prober speaks sing-box's
    // stream transports, not Xray's. A raw TLS probe here misreads xhttp as a
    // dead node ("did not carry the test request"). It runs through the Xray
    // socks bridge and is measured live when the tunnel is up (the auto-pool
    // pings it there), so say that plainly instead of spending a connection to
    // reach a wrong verdict.
    return const NodeProbeResult.untestable(
        'xhttp is verified when you connect');
  }
  if (!n.tls && transport != 'ws' && transport != 'httpupgrade') {
    // Plaintext TCP with no application handshake we can speak: a completed
    // connect is the exact measurement that was lying before.
    return const NodeProbeResult.untestable(
        'plain TCP cannot be verified from outside');
  }

  final Stopwatch sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(n.server, n.port, timeout: timeout);
    final Socket stream = n.tls ? await _wrapTls(raw, n, timeout) : raw;

    switch (transport) {
      // Both carry the same HTTP/1.1 upgrade handshake; they differ only in what
      // the stream looks like afterwards, so the proxied tier is framed for ws
      // and raw for httpupgrade.
      case 'ws':
      case 'httpupgrade':
        final bool framed = transport == 'ws';
        final _Reader reader = _Reader(stream);
        try {
          if (!await _wsUpgrade(stream, reader, n, timeout)) {
            return const NodeProbeResult.unreachable(
                reason: 'the server refused the upgrade on this path');
          }
          final int handshakeMs = sw.elapsedMilliseconds;
          if (deep) {
            final int? ms = framed
                ? await _proxiedOverWs(stream, reader, n, timeout)
                : await _proxiedOverRaw(stream, reader, n, timeout);
            if (ms != null) {
              return NodeProbeResult(NodeProbeQuality.proxied, latencyMs: ms);
            }
          }
          return NodeProbeResult(NodeProbeQuality.handshake,
              latencyMs: handshakeMs);
        } finally {
          reader.cancel();
        }

      case 'grpc':
        final _Reader reader = _Reader(stream);
        try {
          if (!await _h2Settings(stream, reader, timeout)) {
            return const NodeProbeResult.unreachable(
                reason: 'no HTTP/2 response');
          }
          return NodeProbeResult(NodeProbeQuality.handshake,
              latencyMs: sw.elapsedMilliseconds);
        } finally {
          reader.cancel();
        }

      default:
        // Raw TCP inside TLS. The TLS handshake alone is the old lie, so the
        // only honest verdict comes from actually moving data through the node.
        if (!deep) {
          return const NodeProbeResult.untestable(
              'needs a full test to be verified');
        }
        final _Reader reader = _Reader(stream);
        try {
          final int? ms = await _proxiedOverRaw(stream, reader, n, timeout);
          if (ms != null) {
            return NodeProbeResult(NodeProbeQuality.proxied, latencyMs: ms);
          }
          return const NodeProbeResult.untestable(
              'the server accepted TLS but did not carry the test request');
        } finally {
          reader.cancel();
        }
    }
  } on SocketException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on HandshakeException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on TimeoutException {
    return const NodeProbeResult.unreachable(reason: 'timed out');
  } finally {
    raw?.destroy();
  }
}

/// Wraps the connected socket in TLS using the node's own SNI, which is the
/// name the censor inspects. Certificates are accepted unconditionally: a Nova
/// node with no domain runs a self-signed certificate on purpose, and this is a
/// reachability measurement, not a trust decision. Nothing is sent that a bad
/// certificate could expose beyond the probe request itself.
Future<Socket> _wrapTls(Socket raw, ProxyNode n, Duration timeout) async {
  final String host = (n.sni?.isNotEmpty ?? false)
      ? n.sni!
      : (n.wsHost?.isNotEmpty ?? false)
          ? n.wsHost!
          : n.server;
  // ALPN is pinned to what the probe itself speaks, not to what the node
  // advertises: a node offering h2 would otherwise negotiate it and then answer
  // our HTTP/1.1 upgrade with a protocol error, reading as a dead server.
  final List<String> alpn = n.protocol == NodeProtocol.naive
      ? const <String>['h2']
      : switch (n.network.toLowerCase()) {
          'grpc' => const <String>['h2'],
          'ws' || 'httpupgrade' => const <String>['http/1.1'],
          _ => n.alpn,
        };
  return SecureSocket.secure(
    raw,
    host: host,
    onBadCertificate: (_) => true,
    supportedProtocols: alpn.isEmpty ? null : alpn,
  ).timeout(timeout);
}

/// Performs the WebSocket upgrade the node's transport expects. A 101 proves the
/// real server answered on the real path: Cloudflare's edge will complete TCP
/// and TLS for any address it owns, but only the worker behind this node's path
/// returns the upgrade.
Future<bool> _wsUpgrade(
  Socket stream,
  _Reader reader,
  ProxyNode n,
  Duration timeout,
) async {
  final String host = (n.wsHost?.isNotEmpty ?? false)
      ? n.wsHost!
      : (n.sni?.isNotEmpty ?? false)
          ? n.sni!
          : n.server;
  final String path =
      (n.wsPath?.isNotEmpty ?? false) ? n.wsPath! : '/';
  final String key = base64.encode(
      List<int>.generate(16, (_) => _rand.nextInt(256)));
  stream.write('GET $path HTTP/1.1\r\n'
      'Host: $host\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: $key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      'User-Agent: Mozilla/5.0\r\n'
      '\r\n');
  await stream.flush();
  final String? head = await reader.readUntil('\r\n\r\n', timeout);
  return head != null && head.startsWith('HTTP/1.1 101');
}

/// Exchanges HTTP/2 settings frames. gRPC transports run over h2, so a server
/// that negotiated h2 and sent its own SETTINGS frame is really there.
Future<bool> _h2Settings(
    Socket stream, _Reader reader, Duration timeout) async {
  const String preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';
  stream.add(<int>[
    ...utf8.encode(preface),
    // Empty SETTINGS frame: 24-bit length 0, type 0x04, flags 0, stream 0.
    0, 0, 0, 0x04, 0, 0, 0, 0, 0,
  ]);
  await stream.flush();
  final Uint8List? head = await reader.readBytes(9, timeout);
  if (head == null) return false;
  return head[3] == 0x04; // a SETTINGS frame back
}

// ---------------------------------------------------------------------------
// The proxied tier: a real request, through the node, to a host on the internet
// ---------------------------------------------------------------------------

/// The reachability endpoint the probe fetches through the node. Deliberately
/// **not** a Cloudflare host: Nova exits are usually Cloudflare Workers and a
/// Worker cannot relay to Cloudflare's own hostnames (loop protection), so
/// cp.cloudflare.com fails through a perfectly healthy Nova node. Plain HTTP on
/// port 80 keeps the test one round trip with no nested TLS.
const String _probeHost = 'www.gstatic.com';
const int _probePort = 80;
const String _probeRequest = 'GET /generate_204 HTTP/1.1\r\n'
    'Host: $_probeHost\r\n'
    'User-Agent: Mozilla/5.0\r\n'
    'Connection: close\r\n'
    '\r\n';

/// True when the bytes read back are an HTTP response the origin would send.
bool _isHttpReply(String s) {
  if (!s.startsWith('HTTP/1.')) return false;
  final int code = int.tryParse(s.substring(9, min(12, s.length))) ?? 0;
  return code >= 200 && code < 500;
}

/// Runs the proxied request over a raw (TLS) stream: write the protocol's own
/// request header, then speak HTTP to the destination through it.
Future<int?> _proxiedOverRaw(
  Socket stream,
  _Reader reader,
  ProxyNode n,
  Duration timeout,
) async {
  final List<int>? header = _requestHeader(n);
  if (header == null) return null;
  final Stopwatch sw = Stopwatch()..start();
  stream.add(<int>[...header, ...utf8.encode(_probeRequest)]);
  await stream.flush();
  final String? reply = await reader.readUntil('\r\n', timeout, skip: _skip(n));
  if (reply == null) return null;
  return _isHttpReply(reply) ? sw.elapsedMilliseconds : null;
}

/// Same request, but framed as WebSocket binary messages, which is how the
/// worker transports carry it.
Future<int?> _proxiedOverWs(
  Socket stream,
  _Reader reader,
  ProxyNode n,
  Duration timeout,
) async {
  final List<int>? header = _requestHeader(n);
  if (header == null) return null;
  final Stopwatch sw = Stopwatch()..start();
  stream.add(_wsFrame(<int>[...header, ...utf8.encode(_probeRequest)]));
  await stream.flush();
  final List<int>? payload = await _readWsPayload(reader, timeout);
  if (payload == null) return null;
  // The protocol's own response header comes first; find the HTTP reply inside.
  final String text = _latin1(payload);
  final int at = text.indexOf('HTTP/1.');
  if (at < 0) return null;
  return _isHttpReply(text.substring(at)) ? sw.elapsedMilliseconds : null;
}

/// The number of leading response bytes the protocol adds before the
/// destination's own data, so the reader can step over them.
int _skip(ProxyNode n) => n.protocol == NodeProtocol.vless ? 2 : 0;

/// Builds the protocol request header that tells the node where to connect.
///
/// Only VLESS and Trojan are built here: both are a plain, unencrypted header in
/// front of the payload, so the request is exact rather than approximated. VMess
/// and Shadowsocks encrypt their headers, and reimplementing their ciphers to
/// measure a ping would be a second, unverified crypto implementation to keep
/// correct, so those nodes stop at the handshake tier instead.
List<int>? _requestHeader(ProxyNode n) {
  // A node that negotiates XTLS Vision changes the stream framing after the
  // header; a probe that ignores that would misread a healthy node as broken.
  if ((n.flow ?? '').isNotEmpty) return null;
  switch (n.protocol) {
    case NodeProtocol.vless:
      final Uint8List? uuid = _uuidBytes(n.uuid);
      if (uuid == null) return null;
      return <int>[
        0, // version
        ...uuid,
        0, // no addons
        1, // TCP connect
        (_probePort >> 8) & 0xff, _probePort & 0xff,
        2, // address type: domain
        _probeHost.length,
        ...utf8.encode(_probeHost),
      ];
    case NodeProtocol.trojan:
      final String? password = n.password;
      if (password == null || password.isEmpty) return null;
      final String hex = sha224.convert(utf8.encode(password)).toString();
      return <int>[
        ...utf8.encode(hex),
        0x0d, 0x0a,
        1, // CONNECT
        3, // address type: domain
        _probeHost.length,
        ...utf8.encode(_probeHost),
        (_probePort >> 8) & 0xff, _probePort & 0xff,
        0x0d, 0x0a,
      ];
    case NodeProtocol.vmess:
    case NodeProtocol.shadowsocks:
    case NodeProtocol.hysteria2:
    case NodeProtocol.tuic:
    case NodeProtocol.awg:
    case NodeProtocol.socks:
    case NodeProtocol.http:
    // Naive's CONNECT rides inside HTTP/2 with a padding scheme; it has no
    // plain header to write, so it stops at the handshake tier.
    case NodeProtocol.naive:
      return null;
  }
}

/// Parses the canonical 8-4-4-4-12 UUID text into its 16 bytes.
Uint8List? _uuidBytes(String? uuid) {
  if (uuid == null) return null;
  final String hex = uuid.replaceAll('-', '').trim();
  if (hex.length != 32) return null;
  final Uint8List out = Uint8List(16);
  for (int i = 0; i < 16; i++) {
    final int? b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

// ---------------------------------------------------------------------------
// WebSocket framing (client frames must be masked; server frames are not)
// ---------------------------------------------------------------------------

final Random _rand = Random.secure();

/// One masked binary frame carrying [payload].
List<int> _wsFrame(List<int> payload) {
  final List<int> out = <int>[0x82]; // FIN + binary
  final int len = payload.length;
  if (len < 126) {
    out.add(0x80 | len);
  } else if (len < 65536) {
    out.addAll(<int>[0x80 | 126, (len >> 8) & 0xff, len & 0xff]);
  } else {
    out.add(0x80 | 127);
    for (int i = 7; i >= 0; i--) {
      out.add((len >> (8 * i)) & 0xff);
    }
  }
  final List<int> mask = List<int>.generate(4, (_) => _rand.nextInt(256));
  out.addAll(mask);
  for (int i = 0; i < len; i++) {
    out.add(payload[i] ^ mask[i & 3]);
  }
  return out;
}

/// Reads one server frame's payload. Control frames (ping/close) are skipped so
/// a server that pings first does not read as a failure.
Future<List<int>?> _readWsPayload(_Reader reader, Duration timeout) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final Duration left = timeout - sw.elapsed;
    final Uint8List? head = await reader.readBytes(2, left);
    if (head == null) return null;
    final int opcode = head[0] & 0x0f;
    final bool masked = (head[1] & 0x80) != 0;
    int len = head[1] & 0x7f;
    if (len == 126) {
      final Uint8List? ext = await reader.readBytes(2, left);
      if (ext == null) return null;
      len = (ext[0] << 8) | ext[1];
    } else if (len == 127) {
      final Uint8List? ext = await reader.readBytes(8, left);
      if (ext == null) return null;
      len = 0;
      for (final int b in ext) {
        len = (len << 8) | b;
      }
    }
    List<int> mask = const <int>[];
    if (masked) {
      final Uint8List? m = await reader.readBytes(4, left);
      if (m == null) return null;
      mask = m;
    }
    // Guard against a hostile or confused length claim.
    if (len < 0 || len > 1 << 20) return null;
    final Uint8List? body =
        len == 0 ? Uint8List(0) : await reader.readBytes(len, left);
    if (body == null) return null;
    final List<int> payload = masked
        ? <int>[for (int i = 0; i < body.length; i++) body[i] ^ mask[i & 3]]
        : body;
    if (opcode == 0x8) return null; // close
    if (opcode == 0x9 || opcode == 0xa) continue; // ping / pong
    return payload;
  }
  return null;
}

// ---------------------------------------------------------------------------
// SOCKS / HTTP proxy nodes
// ---------------------------------------------------------------------------

Future<NodeProbeResult> _probeSocks5(
  ProxyNode n,
  Duration timeout, {
  required bool deep,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  Socket? sock;
  try {
    sock = await Socket.connect(n.server, n.port, timeout: timeout);
    final _Reader reader = _Reader(sock);
    try {
      sock.add(<int>[0x05, 0x02, 0x00, 0x02]); // no-auth or user/pass
      await sock.flush();
      final Uint8List? greeting = await reader.readBytes(2, timeout);
      if (greeting == null || greeting[0] != 0x05 || greeting[1] == 0xff) {
        return const NodeProbeResult.unreachable(
            reason: 'not a SOCKS5 server');
      }
      final int handshakeMs = sw.elapsedMilliseconds;
      // Only a no-auth server can be driven further without sending the
      // credentials; an authenticating one stops at the handshake tier.
      if (deep && greeting[1] == 0x00) {
        sock.add(<int>[
          0x05, 0x01, 0x00,
          0x03, _probeHost.length, ...utf8.encode(_probeHost),
          (_probePort >> 8) & 0xff, _probePort & 0xff,
        ]);
        await sock.flush();
        final Uint8List? reply = await reader.readBytes(4, timeout);
        if (reply != null && reply[1] == 0x00) {
          // Step over the bound address the server echoes back.
          int addrLen;
          switch (reply[3]) {
            case 0x01:
              addrLen = 4;
            case 0x04:
              addrLen = 16;
            case 0x03:
              addrLen = (await reader.readBytes(1, timeout))?.first ?? -1;
            default:
              addrLen = -1;
          }
          if (addrLen >= 0 &&
              await reader.readBytes(addrLen + 2, timeout) != null) {
            sock.add(utf8.encode(_probeRequest));
            await sock.flush();
            final String? http = await reader.readUntil('\r\n', timeout);
            if (http != null && _isHttpReply(http)) {
              return NodeProbeResult(NodeProbeQuality.proxied,
                  latencyMs: sw.elapsedMilliseconds);
            }
          }
        }
      }
      return NodeProbeResult(NodeProbeQuality.handshake,
          latencyMs: handshakeMs);
    } finally {
      reader.cancel();
    }
  } on SocketException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on TimeoutException {
    return const NodeProbeResult.unreachable(reason: 'timed out');
  } finally {
    sock?.destroy();
  }
}

Future<NodeProbeResult> _probeHttpProxy(
  ProxyNode n,
  Duration timeout, {
  required bool deep,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(n.server, n.port, timeout: timeout);
    final Socket stream = n.tls ? await _wrapTls(raw, n, timeout) : raw;
    final _Reader reader = _Reader(stream);
    try {
      // socks/http links carry the username in `uuid` and the password in
      // `password` (see share_link.dart).
      final String user = n.uuid ?? '';
      final String pass = n.password ?? '';
      final String auth = (user.isEmpty && pass.isEmpty)
          ? ''
          : 'Proxy-Authorization: Basic '
              '${base64.encode(utf8.encode('$user:$pass'))}\r\n';
      stream.write('CONNECT $_probeHost:$_probePort HTTP/1.1\r\n'
          'Host: $_probeHost:$_probePort\r\n'
          '$auth'
          '\r\n');
      await stream.flush();
      final String? head = await reader.readUntil('\r\n\r\n', timeout);
      if (head == null) {
        return const NodeProbeResult.unreachable(
            reason: 'the proxy did not answer');
      }
      if (!head.startsWith('HTTP/1.')) {
        return const NodeProbeResult.unreachable(
            reason: 'not an HTTP proxy');
      }
      final int handshakeMs = sw.elapsedMilliseconds;
      if (deep && head.startsWith('HTTP/1.1 200')) {
        stream.write(_probeRequest);
        await stream.flush();
        final String? http = await reader.readUntil('\r\n', timeout);
        if (http != null && _isHttpReply(http)) {
          return NodeProbeResult(NodeProbeQuality.proxied,
              latencyMs: sw.elapsedMilliseconds);
        }
      }
      return NodeProbeResult(NodeProbeQuality.handshake,
          latencyMs: handshakeMs);
    } finally {
      reader.cancel();
    }
  } on SocketException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } on TimeoutException {
    return const NodeProbeResult.unreachable(reason: 'timed out');
  } finally {
    raw?.destroy();
  }
}

// ---------------------------------------------------------------------------
// QUIC (Hysteria2 / TUIC)
// ---------------------------------------------------------------------------

/// Sends a QUIC packet announcing a version no server implements. Every QUIC
/// server must answer that with a Version Negotiation packet, so a reply is a
/// genuine UDP round trip with the node's own server, the one thing a TCP
/// connect could never tell us about a UDP protocol. Hysteria2 and TUIC both
/// run on quic-go, which answers this.
Future<NodeProbeResult> _probeQuic(ProxyNode n, Duration timeout) async {
  RawDatagramSocket? sock;
  try {
    final InternetAddress? addr = await _resolve(n.server, timeout);
    if (addr == null) {
      return const NodeProbeResult.unreachable(reason: 'address not found');
    }
    sock = await RawDatagramSocket.bind(
      addr.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    final Completer<int?> done = Completer<int?>();
    final Stopwatch sw = Stopwatch()..start();
    final StreamSubscription<RawSocketEvent> sub =
        sock.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) return;
      final Datagram? d = sock?.receive();
      if (d == null || d.data.isEmpty) return;
      // Any well-formed answer proves a QUIC server replied. A long-header
      // packet with version 0 is the version-negotiation answer we asked for.
      if (!done.isCompleted) done.complete(sw.elapsedMilliseconds);
    });
    sock.send(_quicVersionProbe(), addr, n.port);
    final int? ms = await done.future.timeout(timeout, onTimeout: () => null);
    await sub.cancel();
    if (ms == null) {
      return const NodeProbeResult.unreachable(
          reason: 'no QUIC reply (UDP may be blocked)');
    }
    return NodeProbeResult(NodeProbeQuality.handshake, latencyMs: ms);
  } on SocketException catch (e) {
    return NodeProbeResult.unreachable(reason: _short(e));
  } finally {
    sock?.close();
  }
}

/// A QUIC long-header packet using a reserved version, padded past the 1200-byte
/// minimum a server requires before it will answer at all.
Uint8List _quicVersionProbe() {
  final BytesBuilder b = BytesBuilder();
  b.addByte(0xc3); // long header, fixed bit, Initial, 4-byte packet number
  b.add(<int>[0x1a, 0x2a, 0x3a, 0x4a]); // a version no server implements
  b.addByte(8);
  b.add(List<int>.generate(8, (_) => _rand.nextInt(256))); // destination CID
  b.addByte(8);
  b.add(List<int>.generate(8, (_) => _rand.nextInt(256))); // source CID
  final Uint8List head = b.takeBytes();
  final Uint8List out = Uint8List(1250);
  out.setRange(0, head.length, head);
  return out;
}

Future<InternetAddress?> _resolve(String host, Duration timeout) async {
  final InternetAddress? literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  try {
    final List<InternetAddress> found =
        await InternetAddress.lookup(host).timeout(timeout);
    return found.isEmpty ? null : found.first;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Buffered reader
// ---------------------------------------------------------------------------

/// Buffers a socket so the probes can ask for "n bytes" or "up to this marker"
/// with a deadline, which raw stream sockets do not offer.
class _Reader {
  _Reader(Stream<Uint8List> source) {
    _sub = source.listen(
      (Uint8List data) {
        _buf.addAll(data);
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buf = <int>[];
  bool _closed = false;
  Completer<void>? _waiter;

  void _wake() {
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<bool> _await(Duration timeout) async {
    if (_closed) return false;
    final Completer<void> w = Completer<void>();
    _waiter = w;
    try {
      await w.future.timeout(timeout);
      return true;
    } on TimeoutException {
      _waiter = null;
      return false;
    }
  }

  /// Exactly [n] bytes, or null if the socket closed or the deadline passed.
  Future<Uint8List?> readBytes(int n, Duration timeout) async {
    final Stopwatch sw = Stopwatch()..start();
    while (_buf.length < n) {
      final Duration left = timeout - sw.elapsed;
      if (left <= Duration.zero) return null;
      if (!await _await(left)) return null;
    }
    final Uint8List out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  /// Everything up to and including [marker], decoded as latin-1 so byte values
  /// survive intact. [skip] drops that many leading bytes first (a protocol's
  /// own response header). Null on close or deadline.
  Future<String?> readUntil(String marker, Duration timeout,
      {int skip = 0}) async {
    if (skip > 0 && await readBytes(skip, timeout) == null) return null;
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      final int at = _latin1(_buf).indexOf(marker);
      if (at >= 0) {
        final int end = at + marker.length;
        final String out = _latin1(_buf.sublist(0, end));
        _buf.removeRange(0, end);
        return out;
      }
      if (_buf.length > 64 * 1024) return null;
      final Duration left = timeout - sw.elapsed;
      if (left <= Duration.zero) return null;
      if (!await _await(left)) return null;
    }
  }

  void cancel() {
    unawaited(_sub.cancel());
  }
}

String _latin1(List<int> bytes) => String.fromCharCodes(bytes);

// ---------------------------------------------------------------------------
// Test hooks
//
// The wire formats above are the part that has to be exactly right and the part
// a network test cannot check (a probe that silently builds a malformed VLESS
// header just reports every node as unproven, which looks like censorship).
// These expose them to unit tests without opening them up as API.
// ---------------------------------------------------------------------------

@visibleForTesting
List<int>? debugRequestHeader(ProxyNode n) => _requestHeader(n);

@visibleForTesting
List<int> debugWsFrame(List<int> payload) => _wsFrame(payload);

@visibleForTesting
Uint8List debugQuicVersionProbe() => _quicVersionProbe();

@visibleForTesting
bool debugIsHttpReply(String s) => _isHttpReply(s);

/// A short, user-facing reason from a socket failure, without the stack noise.
String _short(Object e) {
  if (e is SocketException) {
    final String m = e.osError?.message ?? e.message;
    return m.isEmpty ? 'connection failed' : m.toLowerCase();
  }
  if (e is HandshakeException) return 'TLS handshake failed';
  if (e is TimeoutException) return 'timed out';
  final String s = e.toString();
  return s.length > 80 ? '${s.substring(0, 77)}...' : s;
}
