import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Speaks the Nova full-tunnel op protocol to a node `/tunnel` exit (see
/// nova-node-agent src/tunnel.mjs). Each call is one JSON round-trip carried by
/// [_inner], which may be a fronted / insecure / plain client, so the tunnel can
/// ride the same domain-fronted Google path as the relay.
///
///   connect(h,p) -> id      data(id, bytes) -> (serverBytes, closed)      close(id)
///
/// It is request/response, so throughput is low; it exists for reachability, not
/// speed. One [RelayTunnel] can carry many sessions (ids) concurrently.
class RelayTunnel {
  RelayTunnel({
    required this.endpoint,
    required this.authKey,
    http.Client? inner,
    this.opTimeout = const Duration(seconds: 30),
  }) : _inner = inner ?? http.Client();

  /// The node `/tunnel` URL, or an Apps Script `/exec` that forwards to it.
  final String endpoint;
  final String authKey;
  final Duration opTimeout;
  final http.Client _inner;

  Future<Map<String, dynamic>> _op(Map<String, dynamic> op) async {
    final http.Response r = await _inner
        .post(
          Uri.parse(endpoint),
          headers: <String, String>{'content-type': 'application/json'},
          body: jsonEncode(<String, dynamic>{...op, 'k': authKey}),
        )
        .timeout(opTimeout);
    if (r.statusCode >= 400) {
      throw TunnelException('tunnel HTTP ${r.statusCode}');
    }
    final Map<String, dynamic> j =
        jsonDecode(r.body) as Map<String, dynamic>;
    if (j['e'] != null) throw TunnelException(j['e'].toString());
    return j;
  }

  /// Open a TCP flow to [host]:[port], returning the session id.
  Future<String> connect(String host, int port) async {
    final Map<String, dynamic> j =
        await _op(<String, dynamic>{'op': 'connect', 'h': host, 'p': port});
    return j['id'] as String;
  }

  /// Write [send] (may be empty to just poll) and return whatever the exit has
  /// buffered back, plus whether the upstream socket has closed.
  Future<(Uint8List, bool)> data(String id, List<int> send) async {
    final Map<String, dynamic> j = await _op(<String, dynamic>{
      'op': 'data',
      'id': id,
      if (send.isNotEmpty) 'd': base64.encode(send),
    });
    final String? d = j['d'] as String?;
    final Uint8List bytes = (d != null && d.isNotEmpty)
        ? base64.decode(d)
        : Uint8List(0);
    return (bytes, j['closed'] == true);
  }

  Future<void> closeSession(String id) async {
    try {
      await _op(<String, dynamic>{'op': 'close', 'id': id});
    } catch (_) {/* best effort */}
  }

  void close() => _inner.close();
}

class TunnelException implements Exception {
  TunnelException(this.message);
  final String message;
  @override
  String toString() => 'TunnelException: $message';
}

/// A local SOCKS5 proxy on 127.0.0.1 that carries every CONNECT through a
/// [RelayTunnel]. Point an app (or the browser) at `SOCKS5 127.0.0.1:<port>`
/// and its TCP flows travel out through the tunnel exit. CONNECT (TCP) only; UDP
/// ASSOCIATE is not offered (the op protocol supports UDP, but few apps need it
/// over a last-resort path).
class LocalSocks5 {
  LocalSocks5({required this.tunnelFactory, this.host = '127.0.0.1'});

  /// Builds a fresh [RelayTunnel] (its own inner client) per accepted socket, so
  /// one slow flow can't head-of-line-block another.
  final RelayTunnel Function() tunnelFactory;
  final String host;

  ServerSocket? _server;
  final Set<Socket> _clients = <Socket>{};

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  /// Bind and start accepting. Returns the bound port (0 lets the OS choose).
  Future<int> start(int desiredPort) async {
    if (_server != null) return _server!.port;
    _server = await ServerSocket.bind(host, desiredPort);
    _server!.listen(_accept, onError: (_) {});
    return _server!.port;
  }

  Future<void> stop() async {
    final ServerSocket? s = _server;
    _server = null;
    await s?.close();
    for (final Socket c in _clients.toList()) {
      c.destroy();
    }
    _clients.clear();
  }

  Future<void> _accept(Socket client) async {
    _clients.add(client);
    final _ByteReader reader = _ByteReader(client);
    RelayTunnel? tunnel;
    String? sessionId;
    try {
      // --- SOCKS5 greeting: [ver, nmethods, methods...] -> [5, 0] (no auth) ---
      final int ver = await reader.byte();
      if (ver != 0x05) throw const SocketException('not socks5');
      final int nMethods = await reader.byte();
      await reader.take(nMethods);
      client.add(<int>[0x05, 0x00]);

      // --- request: [ver, cmd, rsv, atyp, addr, port] ---
      final Uint8List head = await reader.take(4);
      if (head[1] != 0x01) {
        // Only CONNECT is supported; reply "command not supported".
        client.add(<int>[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }
      final int atyp = head[3];
      final String targetHost;
      if (atyp == 0x01) {
        final Uint8List a = await reader.take(4);
        targetHost = a.join('.');
      } else if (atyp == 0x03) {
        final int len = await reader.byte();
        targetHost = utf8.decode(await reader.take(len));
      } else if (atyp == 0x04) {
        final Uint8List a = await reader.take(16);
        targetHost = _formatIpv6(a);
      } else {
        client.add(<int>[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }
      final Uint8List pb = await reader.take(2);
      final int targetPort = (pb[0] << 8) | pb[1];

      // --- open the flow through the tunnel ---
      tunnel = tunnelFactory();
      try {
        sessionId = await tunnel.connect(targetHost, targetPort);
      } on TunnelException {
        client.add(<int>[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]); // refused
        await client.flush();
        client.destroy();
        return;
      }
      // Success reply (bound addr 0.0.0.0:0 is fine for a CONNECT).
      client.add(<int>[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await client.flush();

      await _pump(client, reader, tunnel, sessionId);
    } catch (_) {
      // Any protocol/transport error: just drop the client.
    } finally {
      if (tunnel != null && sessionId != null) {
        await tunnel.closeSession(sessionId);
      }
      tunnel?.close();
      _clients.remove(client);
      client.destroy();
    }
  }

  /// Full-duplex pump over the request/response op protocol. Client bytes that
  /// arrive after the SOCKS handshake are buffered by [reader]; each iteration
  /// flushes them to the exit and writes back whatever the exit returns. The
  /// node long-polls, so an idle loop costs one ~250ms round-trip, not a spin.
  Future<void> _pump(
      Socket client, _ByteReader reader, RelayTunnel tunnel, String id) async {
    bool clientClosed = false;
    while (true) {
      final List<int> pending = reader.drainBuffered();
      if (pending.isEmpty && reader.isDone) clientClosed = true;

      final (Uint8List fromServer, bool serverClosed) =
          await tunnel.data(id, pending);
      if (fromServer.isNotEmpty) {
        client.add(fromServer);
        await client.flush();
      }
      if (serverClosed) break;
      if (clientClosed) break;

      // If nothing moved this round, wait for the client to send or close so we
      // don't hammer the exit with empty polls back to back.
      if (pending.isEmpty && fromServer.isEmpty) {
        await reader.waitForActivity(const Duration(milliseconds: 200));
      }
    }
  }

  static String _formatIpv6(Uint8List a) {
    final List<String> parts = <String>[];
    for (int i = 0; i < 16; i += 2) {
      parts.add(((a[i] << 8) | a[i + 1]).toRadixString(16));
    }
    return parts.join(':');
  }
}

/// Buffers a [Socket]'s incoming bytes so the SOCKS handshake can read exact
/// counts and the pump can drain whatever has arrived without blocking.
class _ByteReader {
  _ByteReader(Socket socket) {
    _sub = socket.listen(
      (Uint8List chunk) {
        _buf.addAll(chunk);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (_) {
        _done = true;
        _wake();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buf = <int>[];
  bool _done = false;
  Completer<void>? _waiter;

  bool get isDone => _done && _buf.isEmpty;

  void _wake() {
    final Completer<void>? w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  /// Read exactly [n] bytes, awaiting more from the socket as needed.
  Future<Uint8List> take(int n) async {
    while (_buf.length < n) {
      if (_done) throw const SocketException('closed mid-frame');
      await _wait();
    }
    final Uint8List out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<int> byte() async => (await take(1))[0];

  /// Take everything buffered right now (may be empty), without waiting.
  List<int> drainBuffered() {
    if (_buf.isEmpty) return const <int>[];
    final List<int> out = List<int>.from(_buf);
    _buf.clear();
    return out;
  }

  /// Resolve when more bytes arrive or the socket closes, or after [timeout].
  Future<void> waitForActivity(Duration timeout) async {
    if (_buf.isNotEmpty || _done) return;
    await _wait(timeout);
  }

  Future<void> _wait([Duration? timeout]) {
    _waiter ??= Completer<void>();
    final Future<void> f = _waiter!.future;
    if (timeout == null) return f;
    return f.timeout(timeout, onTimeout: () {});
  }

  Future<void> dispose() async {
    await _sub.cancel();
  }
}
