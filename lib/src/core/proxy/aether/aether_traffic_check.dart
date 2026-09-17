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

  /// A trace is a few hundred bytes. Anything beyond this is not an answer, it
  /// is something trying to make us read forever, so reading stops here and
  /// what arrived is judged on its own.
  static const int maxBody = 16384;

  /// Deliberately ordinary. A request that names this app is a one line
  /// signature for anything watching, and the case where that matters is
  /// exactly the case this check exists to detect: a request that escaped the
  /// tunnel and crossed the network in the open.
  static const String _agent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Makes one request through the SOCKS5 proxy on [socksPort].
  /// [abort] is polled while the request is in flight. A user who presses
  /// Cancel should not go on holding a WARP session and a loopback port for the
  /// rest of the budget, and the budget here can be twenty seconds.
  static Future<AetherTrafficProof> through(
    int socksPort, {
    Duration budget = const Duration(seconds: 20),
    bool Function()? abort,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    // A budget that has already been spent is zero, not negative. A caller that
    // subtracts elapsed time from a deadline can hand us a negative duration,
    // and reporting "nothing came back within -0s" is worse than useless.
    final Duration limit = budget.isNegative ? Duration.zero : budget;
    // The socket has to be reachable from out here. Dart's `timeout` does not
    // cancel the future it wraps: it completes the outer one and leaves the
    // inner running. Without this handle the read below would keep draining a
    // socket nobody is waiting for any more, which is how a hostile responder
    // turned a five second budget into a gigabyte of memory.
    final _Live live = _Live();
    Timer? watch;
    if (abort != null) {
      watch = Timer.periodic(const Duration(milliseconds: 200), (Timer t) {
        if (!abort()) return;
        t.cancel();
        // Closing the socket is what ends the read; the run then finishes on
        // its own with whatever it had.
        live.close();
      });
    }
    try {
      return await _run(socksPort, clock, live).timeout(limit, onTimeout: () {
        live.close();
        return AetherTrafficProof(
            carried: false,
            ms: clock.elapsedMilliseconds,
            error: 'nothing came back within ${limit.inSeconds}s');
      });
    } catch (e) {
      live.close();
      return AetherTrafficProof(
          carried: false, ms: clock.elapsedMilliseconds, error: _short(e));
    } finally {
      watch?.cancel();
    }
  }

  static Future<AetherTrafficProof> _run(
      int socksPort, Stopwatch clock, _Live live) async {
    final Socket sock = await Socket.connect('127.0.0.1', socksPort);
    final _Reader reader = _Reader(sock);
    live.attach(sock, reader);
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
          'User-Agent: $_agent\r\n'
          'Connection: close\r\n\r\n'));
      await sock.flush();
      final String response = await reader.rest(maxBody);
      if (response.isEmpty) {
        return _failed(clock, 'the tunnel closed without answering');
      }
      // The status line is checked before the body is believed. Without it any
      // response at all that happens to contain a warp line counts as proof,
      // including an error page from something that is not the far end.
      if (!response.startsWith('HTTP/1.1 200') &&
          !response.startsWith('HTTP/1.0 200')) {
        return _failed(clock,
            'the far end answered ${response.split('\r\n').first.trim()}');
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
      // One teardown path, so a normal finish and an expired deadline cannot
      // race each other into closing the same socket twice.
      live.close();
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

  /// Everything still to come, up to [cap] bytes.
  ///
  /// The cap is the point. This used to read to end of stream, and a responder
  /// that never ends turned that into unbounded memory: a growable list of ints
  /// in the Dart VM costs a machine word per byte, so a few hundred megabytes
  /// on the wire became gigabytes resident, and it kept growing after the
  /// caller had already given up.
  Future<String> rest(int cap) async {
    while (_buf.length < cap && await _it.moveNext()) {
      _buf.addAll(_it.current);
    }
    return utf8.decode(
        _buf.length > cap ? _buf.sublist(0, cap) : _buf,
        allowMalformed: true);
  }

  /// Safe to call more than once: the deadline and the normal finish can both
  /// reach here, and cancelling an already cancelled iterator throws.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _it.cancel();
    _buf.clear();
  }

  bool _cancelled = false;
}

/// The socket and reader a run is currently using, so a deadline that fires
/// outside that run can still shut them down.
///
/// Dart's `timeout` completes the outer future and walks away; the work it
/// wrapped keeps going. For a network read that means the socket stays open and
/// the buffer keeps filling long after an answer stopped being wanted. Holding
/// the pieces here is what makes the deadline actually end the work.
class _Live {
  Socket? _sock;
  _Reader? _reader;
  bool _closed = false;

  void attach(Socket sock, _Reader reader) {
    if (_closed) {
      // The deadline fired while the connection was still being made.
      sock.destroy();
      return;
    }
    _sock = sock;
    _reader = reader;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _reader?.cancel();
    _sock?.destroy();
    _sock = null;
    _reader = null;
  }
}
