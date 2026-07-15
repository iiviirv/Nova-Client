import 'dart:async';
import 'dart:io';

import 'proxy_node.dart';

/// Measures whether a node is actually reachable, returning the latency in ms
/// or null when it is not.
///
/// A bare TCP connect is a lie for Cloudflare-fronted nodes: the anycast edge
/// accepts every TCP handshake, while Iran's DPI kills the *TLS* handshake that
/// carries the SNI (e.g. *.workers.dev). That is exactly the "all configs ping
/// green but none of them work" report. So for TLS nodes we complete a real TLS
/// handshake with the node's own SNI; only plaintext nodes fall back to the TCP
/// connect. UDP-native protocols (Hysteria2/TUIC) run over QUIC and cannot be
/// probed with a TCP-based handshake, so they keep the plain connect as a
/// best-effort liveness hint.
Future<int?> probeNodeMs(
  ProxyNode n, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(n.server, n.port, timeout: timeout);
    if (n.tls && !n.protocol.isUdpNative) {
      final String host = (n.sni?.isNotEmpty ?? false)
          ? n.sni!
          : (n.wsHost?.isNotEmpty ?? false)
              ? n.wsHost!
              : n.server;
      // Reachability only: accept any certificate (some nodes run with
      // allowInsecure), we just need the ServerHello to make it back past DPI.
      final SecureSocket tls = await SecureSocket.secure(
        socket,
        host: host,
        onBadCertificate: (_) => true,
      ).timeout(timeout);
      sw.stop();
      tls.destroy();
      return sw.elapsedMilliseconds;
    }
    sw.stop();
    socket.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    socket?.destroy();
    return null;
  }
}
