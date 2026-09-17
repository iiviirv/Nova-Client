import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
/// The core has its own verification call and it is unusable on a slow path:
/// it applies a fixed five second budget and reports everything that misses it
/// as simply unreachable. Measured on 2026-09-16 by degrading only the route to
/// one known-good gateway, a healthy endpoint verifies in 505ms on a clean
/// network, 3.0 to 3.5s at 600ms RTT with 5% loss, and then fails three times
/// out of three at 1200ms RTT with 10% loss, with a result byte-identical to a
/// black hole. That is a working gateway being reported as broken, which is
/// what testers in Iran were hitting.
///
/// The oracle is Cloudflare's own trace, over TLS.
///
/// TLS is not decoration here. The interesting case is a tunnel that answers
/// but does not actually tunnel, and in that case the request crosses the
/// user's ordinary network in the open. Over plain HTTP anyone on the path
/// could answer `warp=on` and have Nova record a gateway that provides no
/// protection as proven, which defeats the only check that tells a real tunnel
/// from a leak. The certificate is what makes the answer worth believing.
abstract final class AetherTrafficCheck {
  /// Where the proof is fetched from. A parameter rather than a constant so a
  /// test can point the check at its own server; the scheme decides whether the
  /// connection is upgraded, so nothing here can quietly downgrade production.
  static final Uri defaultTarget =
      Uri.parse('https://www.cloudflare.com/cdn-cgi/trace');

  /// A trace is a few hundred bytes. Anything beyond this is not an answer, it
  /// is something trying to make us read forever, so reading stops here and
  /// what arrived is judged on its own.
  static const int maxBody = 16384;

  /// Deliberately ordinary. A request that names this app is a one line
  /// signature for anything watching, and the case where that matters is
  /// exactly the case this check exists to detect.
  static const String _agent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Makes one request through the SOCKS5 proxy on [socksPort].
  ///
  /// [abort] is polled while the request is in flight. A user who presses
  /// Cancel should not go on holding a WARP session and a loopback port for the
  /// rest of the budget, and the budget here can be twenty seconds.
  static Future<AetherTrafficProof> through(
    int socksPort, {
    Duration budget = const Duration(seconds: 20),
    bool Function()? abort,
    Uri? target,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    // A budget that has already been spent is zero, not negative. A caller that
    // subtracts elapsed time from a deadline can hand us a negative duration,
    // and reporting "nothing came back within -0s" is worse than useless.
    final Duration limit = budget.isNegative ? Duration.zero : budget;
    final Uri to = target ?? defaultTarget;

    // The wire has to be reachable from out here. Dart's `timeout` does not
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
        live.close();
      });
    }
    try {
      return await _run(socksPort, to, clock, live).timeout(limit,
          onTimeout: () {
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
      int socksPort, Uri to, Stopwatch clock, _Live live) async {
    final int port = to.hasPort ? to.port : (to.scheme == 'https' ? 443 : 80);
    final RawSocket raw = await RawSocket.connect('127.0.0.1', socksPort);
    final _Wire wire = _Wire(raw);
    live.attach(wire);
    try {
      // Greeting: SOCKS5, one method, no authentication. The tunnel serves a
      // loopback port for this process alone, so there is nothing to
      // authenticate to.
      wire.write(<int>[0x05, 0x01, 0x00]);
      final List<int>? hello = await wire.take(2);
      if (hello == null || hello[0] != 0x05 || hello[1] != 0x00) {
        return _failed(clock, 'the tunnel port did not answer as SOCKS5');
      }

      // CONNECT by name rather than address, so the far end resolves it. A
      // client that resolved first would be asking the local resolver a
      // question the tunnel exists to avoid asking.
      final List<int> name = utf8.encode(to.host);
      wire.write(<int>[
        0x05, 0x01, 0x00,
        0x03, name.length, ...name,
        (port >> 8) & 0xff, port & 0xff,
      ]);
      final List<int>? reply = await wire.take(4);
      if (reply == null || reply[1] != 0x00) {
        return _failed(clock,
            'the tunnel refused to connect (${_socksError(reply?[1])})');
      }
      // Step over the bound address the proxy echoes back.
      final int addrLen = switch (reply[3]) {
        0x01 => 4,
        0x04 => 16,
        0x03 => (await wire.take(1))?.first ?? -1,
        _ => -1,
      };
      if (addrLen < 0 || await wire.take(addrLen + 2) == null) {
        return _failed(clock, 'the tunnel sent a reply that made no sense');
      }

      if (to.scheme == 'https') await wire.upgrade(to.host);

      wire.write(utf8.encode('GET ${to.path} HTTP/1.1\r\n'
          'Host: ${to.host}\r\n'
          'User-Agent: $_agent\r\n'
          'Connection: close\r\n\r\n'));
      final String response = await wire.rest(maxBody);
      if (response.isEmpty) {
        return _failed(clock, 'the tunnel closed without answering');
      }
      // The status line is checked before the body is believed. Without it any
      // response at all that happens to contain a warp line counts as proof,
      // including an error page from something that is not the far end.
      if (!response.startsWith('HTTP/1.1 200') &&
          !response.startsWith('HTTP/1.0 200')) {
        return _failed(
            clock, 'the far end answered ${response.split('\r\n').first.trim()}');
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
    final String body = blank < 0 ? response : response.substring(blank + 4);
    final Map<String, String> out = <String, String>{};
    for (final String line in const LineSplitter().convert(body)) {
      final int eq = line.indexOf('=');
      if (eq > 0) {
        out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
      }
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

/// A byte pipe that can be upgraded to TLS part way through.
///
/// A plain `Socket` cannot do this: securing one needs the stream not to have
/// been consumed, and the SOCKS handshake has to be read before the upgrade can
/// happen. `RawSecureSocket.secure` takes the socket and its subscription
/// together for exactly this reason, and a `RawSecureSocket` is itself a
/// `RawSocket`, so the same pipe carries on afterwards.
class _Wire {
  _Wire(this._sock) {
    _sub = _sock.listen(_onEvent);
  }

  RawSocket _sock;
  late StreamSubscription<RawSocketEvent> _sub;
  final List<int> _buf = <int>[];
  bool _done = false;
  Completer<void>? _waiter;

  void _onEvent(RawSocketEvent e) {
    if (e == RawSocketEvent.read) {
      final Uint8List? d = _sock.read();
      if (d != null) _buf.addAll(d);
    } else if (e == RawSocketEvent.readClosed || e == RawSocketEvent.closed) {
      _done = true;
    }
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void write(List<int> bytes) {
    int off = 0;
    while (off < bytes.length) {
      final int n = _sock.write(bytes, off, bytes.length - off);
      if (n <= 0) break;
      off += n;
    }
  }

  Future<List<int>?> take(int n) async {
    while (_buf.length < n) {
      if (_done) return null;
      _waiter = Completer<void>();
      await _waiter!.future;
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
    while (_buf.length < cap && !_done) {
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final List<int> out = _buf.length > cap ? _buf.sublist(0, cap) : _buf;
    return utf8.decode(out, allowMalformed: true);
  }

  Future<void> upgrade(String host) async {
    final RawSecureSocket sec =
        await RawSecureSocket.secure(_sock, subscription: _sub, host: host);
    _sock = sec;
    _sub = sec.listen(_onEvent);
  }

  void close() {
    if (_done && _buf.isEmpty) {
      // Already finished; still make sure the handle is gone.
    }
    _done = true;
    try {
      _sub.cancel();
    } catch (_) {}
    try {
      _sock.close();
    } catch (_) {}
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }
}

/// The wire a run is currently using, so a deadline that fires outside that run
/// can still shut it down.
class _Live {
  _Wire? _wire;
  bool _closed = false;

  void attach(_Wire wire) {
    if (_closed) {
      wire.close();
      return;
    }
    _wire = wire;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _wire?.close();
    _wire = null;
  }
}
