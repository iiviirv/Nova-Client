import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a real request through a tunnel found.
class AetherTrafficProof {
  const AetherTrafficProof({
    required this.carried,
    required this.ms,
    this.warp,
    this.ip,
    this.error,
  });

  /// A response came back through the tunnel. This is the question that
  /// matters: not whether a handshake completed, but whether bytes made the
  /// round trip.
  final bool carried;

  /// How long it took, for the log.
  final int ms;

  /// Cloudflare's own word for whether the request arrived over WARP: `on`,
  /// `plus`, or `off`. Null when nothing came back.
  final String? warp;

  /// The address the far end saw, which is the exit IP.
  final String? ip;

  /// Why nothing came back.
  final String? error;

  /// Traffic moved and it moved through WARP.
  ///
  /// `off` is a real and important failure: it means the request went out
  /// around the tunnel rather than through it, so the endpoint proved nothing.
  bool get viaWarp => carried && (warp == 'on' || warp == 'plus');

  @override
  String toString() => carried
      ? 'carried in ${ms}ms, warp=$warp, ip=$ip'
      : 'nothing carried in ${ms}ms: ${error ?? 'no reason'}';
}

/// Proves a tunnel carries traffic, on a budget this app chooses.
///
/// The core has its own verification call, and it is unusable on a slow path:
/// it applies a fixed five second budget and reports everything that misses it
/// as simply unreachable. Measured on 2026-09-16 by degrading only the route to
/// one known-good gateway, a healthy endpoint verifies in 505ms on a clean
/// network, 3.0 to 3.5s at 600ms RTT with 5% loss, and then fails three times
/// out of three at 1200ms RTT with 10% loss, with a result byte-identical to a
/// black hole. That is a working gateway being reported as a broken one, which
/// is what testers in Iran have been hitting.
///
/// So the check is done here instead. Same gateway, same tunnel payload, but
/// the deadline belongs to the caller.
///
/// The oracle is Cloudflare's own trace over plain HTTP. Plain because TLS on
/// top of a SOCKS socket is awkward in Dart and buys nothing here: the request
/// travels inside the WARP tunnel, so it is encrypted on the wire either way,
/// and it carries nothing about the user. It reports `warp=` as well as the
/// exit address, which is what makes it an honest test. A request that leaked
/// around the tunnel still answers 200, and only the `warp` field tells the
/// two apart.
abstract final class AetherTrafficCheck {
  static const String host = 'www.cloudflare.com';
  static const int port = 80;
  static const String path = '/cdn-cgi/trace';

  /// Makes one request through the SOCKS5 proxy on [socksPort].
  static Future<AetherTrafficProof> through(
    int socksPort, {
    Duration budget = const Duration(seconds: 20),
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    try {
      return await _run(socksPort, clock).timeout(budget);
    } on TimeoutException {
      return AetherTrafficProof(
          carried: false,
          ms: clock.elapsedMilliseconds,
          error: 'nothing came back within ${budget.inSeconds}s');
    } catch (e) {
      return AetherTrafficProof(
          carried: false, ms: clock.elapsedMilliseconds, error: _short(e));
    }
  }

  static Future<AetherTrafficProof> _run(int socksPort, Stopwatch clock) async {
    final Socket sock = await Socket.connect('127.0.0.1', socksPort);
    final _Reader reader = _Reader(sock);
    try {
      // Greeting: SOCKS5, one method, no authentication. The tunnel serves a
      // loopback port for this process alone, so there is nothing to
      // authenticate to.
      sock.add(<int>[0x05, 0x01, 0x00]);
      await sock.flush();
      final List<int>? hello = await reader.take(2);
      if (hello == null || hello[0] != 0x05 || hello[1] != 0x00) {
        return _failed(clock, 'the tunnel port did not answer as SOCKS5');
      }

      // CONNECT, by name rather than address, so the far end resolves it. A
      // client that resolves first would be asking the local resolver a
      // question the tunnel exists to avoid asking.
      final List<int> name = utf8.encode(host);
      sock.add(<int>[
        0x05, 0x01, 0x00,
        0x03, name.length, ...name,
        (port >> 8) & 0xff, port & 0xff,
      ]);
      await sock.flush();
      final List<int>? reply = await reader.take(4);
      if (reply == null || reply[1] != 0x00) {
        return _failed(clock,
            'the tunnel refused to connect (${_socksError(reply?[1])})');
      }
      // Step over the bound address the proxy echoes back.
      final int addrLen = switch (reply[3]) {
        0x01 => 4,
        0x04 => 16,
        0x03 => (await reader.take(1))?.first ?? -1,
        _ => -1,
      };
      if (addrLen < 0 || await reader.take(addrLen + 2) == null) {
        return _failed(clock, 'the tunnel sent a reply that made no sense');
      }

      sock.add(utf8.encode('GET $path HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: Nova\r\n'
          'Connection: close\r\n\r\n'));
      await sock.flush();
      final String response = await reader.rest();
      if (response.isEmpty) {
        return _failed(clock, 'the tunnel closed without answering');
      }
      final Map<String, String> trace = _parse(response);
      if (trace.isEmpty) {
        return _failed(clock, 'the answer was not a trace');
      }
      return AetherTrafficProof(
        carried: true,
        ms: clock.elapsedMilliseconds,
        warp: trace['warp'],
        ip: trace['ip'],
      );
    } finally {
      await reader.cancel();
      sock.destroy();
    }
  }

  static AetherTrafficProof _failed(Stopwatch clock, String why) =>
      AetherTrafficProof(
          carried: false, ms: clock.elapsedMilliseconds, error: why);

  /// The trace body is `key=value` per line, after the HTTP headers.
  static Map<String, String> _parse(String response) {
    final int blank = response.indexOf('\r\n\r\n');
    final String body =
        blank < 0 ? response : response.substring(blank + 4);
    final Map<String, String> out = <String, String>{};
    for (final String line in const LineSplitter().convert(body)) {
      final int eq = line.indexOf('=');
      if (eq > 0) out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    return out;
  }

  static String _socksError(int? code) => switch (code) {
        0x01 => 'general failure',
        0x02 => 'not allowed',
        0x03 => 'network unreachable',
        0x04 => 'host unreachable',
        0x05 => 'connection refused',
        0x06 => 'ttl expired',
        0x07 => 'command not supported',
        0x08 => 'address type not supported',
        null => 'no reply',
        _ => 'code $code',
      };

  static String _short(Object e) {
    final String s = e.toString();
    return s.length <= 120 ? s : '${s.substring(0, 117)}...';
  }
}

/// Reads exact byte counts off a socket, which a raw stream will not do.
class _Reader {
  _Reader(Stream<List<int>> s) : _it = StreamIterator<List<int>>(s);

  final StreamIterator<List<int>> _it;
  final List<int> _buf = <int>[];

  Future<List<int>?> take(int n) async {
    while (_buf.length < n) {
      if (!await _it.moveNext()) return null;
      _buf.addAll(_it.current);
    }
    final List<int> out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  Future<String> rest() async {
    while (await _it.moveNext()) {
      _buf.addAll(_it.current);
    }
    return utf8.decode(_buf, allowMalformed: true);
  }

  Future<void> cancel() => _it.cancel();
}
