import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_traffic_check.dart';

/// How the fake gateway behaves.
enum Behaviour {
  serve,
  refuse,
  notSocks,
  silent,
  hangUp,
  endless,
  huge,
  dribble
}

/// A stand-in for the tunnel's SOCKS5 port.
///
/// The real thing needs the native core and a route to Cloudflare, so the
/// interesting failures (a refusal, a silent proxy, a leak around the tunnel)
/// could otherwise only be seen by breaking someone's network. Here they are
/// just a switch.
Future<ServerSocket> fakeGateway({
  Behaviour how = Behaviour.serve,
  int replyVersion = 5,
  int reserved = 0,
  String status = '200 OK',
  String warp = 'on',
  String ip = '104.28.208.123',
  List<int>? sentCounter,
  List<bool>? clientClosed,
}) async {
  final ServerSocket server =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((Socket sock) async {
    final StreamIterator<List<int>> it = StreamIterator<List<int>>(sock);
    final List<int> buf = <int>[];
    Future<List<int>?> take(int n) async {
      while (buf.length < n) {
        if (!await it.moveNext()) return null;
        buf.addAll(it.current);
      }
      final List<int> out = buf.sublist(0, n);
      buf.removeRange(0, n);
      return out;
    }

    try {
      if (await take(3) == null) return;
      if (how == Behaviour.notSocks) {
        sock.add(utf8.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        await sock.flush();
        return;
      }
      sock.add(<int>[0x05, 0x00]);
      await sock.flush();

      final List<int>? head = await take(4);
      if (head == null) return;
      final int len = (await take(1))?.first ?? 0;
      await take(len + 2);

      if (how == Behaviour.refuse) {
        sock.add(<int>[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await sock.flush();
        return;
      }
      if (how == Behaviour.hangUp) return;
      sock.add(<int>[replyVersion, 0x00, reserved, 0x01, 0, 0, 0, 0, 0, 0]);
      await sock.flush();

      if (await take(1) == null) return;
      if (how == Behaviour.silent) {
        // Accept the request and never answer, which is what a gateway that
        // completes a handshake and then carries nothing looks like.
        await Future<void>.delayed(const Duration(seconds: 10));
        return;
      }
      final String body = 'fl=29f172\nip=$ip\nts=1789598660.000\n'
          'colo=YYZ\nwarp=$warp\ngateway=off\n';
      if (how == Behaviour.dribble) {
        // Answers, then feeds bytes too slowly to ever reach the size cap. The
        // cap cannot end this read, so only tearing the socket down can, which
        // is what makes this a test of the teardown alone.
        sock.add(
            utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n'));
        await sock.flush();
        // Notice when the client goes away. Nothing else here can tell us.
        unawaited(it.moveNext().then((bool more) {
          if (!more && clientClosed != null) clientClosed[0] = true;
        }).catchError((Object _) {
          if (clientClosed != null) clientClosed[0] = true;
        }));
        try {
          for (int i = 0; i < 200; i++) {
            sock.add(List<int>.filled(16, 122));
            await sock.flush();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        } catch (_) {
          if (clientClosed != null) clientClosed[0] = true;
        }
        return;
      }
      if (how == Behaviour.endless) {
        // Answers correctly and then never stops. This is the shape a
        // transparent proxy or an on-path injector takes, and it is the one
        // that used to grow the client's buffer without limit.
        sock.add(
            utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n'));
        await sock.flush();
        final List<int> chunk = List<int>.filled(65536, 65);
        try {
          // Bounded so a regression cannot take the test host down with it.
          while ((sentCounter?[0] ?? 0) < 64 * 1024 * 1024) {
            sock.add(chunk);
            await sock.flush();
            if (sentCounter != null) sentCounter[0] += chunk.length;
          }
        } catch (_) {
          // The client went away, which is the point.
        }
        return;
      }
      if (how == Behaviour.huge) {
        // A correct answer followed by far more than anyone should read. The
        // budget is generous in that test, so only the size cap can stop this.
        sock.add(utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$body'));
        await sock.flush();
        final List<int> chunk = List<int>.filled(65536, 120);
        try {
          while ((sentCounter?[0] ?? 0) < 32 * 1024 * 1024) {
            sock.add(chunk);
            await sock.flush();
            if (sentCounter != null) sentCounter[0] += chunk.length;
          }
        } catch (_) {
          // The client stopped reading, which is the point.
        }
        return;
      }
      sock.add(utf8.encode('HTTP/1.1 $status\r\n'
          'Content-Type: text/plain\r\n'
          'Content-Length: ${body.length}\r\n\r\n$body'));
      await sock.flush();
    } finally {
      if (how != Behaviour.dribble) {
        await it.cancel();
        sock.destroy();
      }
    }
  });
  return server;
}

/// The fake gateway speaks plain HTTP. Production always fetches over TLS;
/// these tests are about the SOCKS handshake, the reading and the deadlines,
/// and they say which target they use rather than relying on a default.
final Uri plain = Uri.parse('http://www.cloudflare.com/cdn-cgi/trace');

void main() {
  test('rejects malformed SOCKS version and reserved byte', () async {
    for (final values in <List<int>>[
      <int>[4, 0],
      <int>[5, 1]
    ]) {
      final server =
          await fakeGateway(replyVersion: values[0], reserved: values[1]);
      try {
        final proof =
            await AetherTrafficCheck.through(server.port, target: plain);
        expect(proof.viaWarp, isFalse);
      } finally {
        await server.close();
      }
    }
  });

  test('a status starting with 200 is not necessarily HTTP success', () async {
    final server = await fakeGateway(status: '2000 Invalid');
    try {
      final proof =
          await AetherTrafficCheck.through(server.port, target: plain);
      expect(proof.viaWarp, isFalse);
    } finally {
      await server.close();
    }
  });

  // The one test that is about the default. Plain HTTP here would let anyone on
  // the path answer warp=on in exactly the case the check exists to catch.
  test('production fetches the proof over TLS', () {
    expect(AetherTrafficCheck.defaultTarget.scheme, 'https');
    expect(AetherTrafficCheck.defaultTarget.host, 'www.cloudflare.com');
  });

  test('a tunnel that carries traffic through WARP passes', () async {
    final ServerSocket g = await fakeGateway(warp: 'on');
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.carried, isTrue);
    expect(p.viaWarp, isTrue);
    expect(p.warp, 'on');
    expect(p.ip, '104.28.208.123');
  });

  test('warp=plus is WARP too', () async {
    final ServerSocket g = await fakeGateway(warp: 'plus');
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.viaWarp, isTrue);
  });

  // The failure the core's own check cannot see. A request that escaped around
  // the tunnel still answers 200, and calling that a working gateway would save
  // an endpoint that proves nothing.
  test('traffic that leaked around the tunnel is not a pass', () async {
    final ServerSocket g = await fakeGateway(warp: 'off');
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.carried, isTrue, reason: 'bytes did move');
    expect(p.viaWarp, isFalse, reason: 'but not through WARP');
  });

  test('a refused connection says so rather than timing out', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.refuse);
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, contains('refused'));
  });

  test('a port that is not SOCKS5 is reported as such', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.notSocks);
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, contains('SOCKS5'));
  });

  test('a proxy that accepts and then goes quiet is bounded by the budget',
      () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.silent);
    final Stopwatch clock = Stopwatch()..start();
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: 2));
    clock.stop();
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, contains('2s'));
    // The budget is the whole point of this class existing, so it has to be
    // the thing that actually stops the wait.
    expect(clock.elapsedMilliseconds, lessThan(4000));
  });

  test('a tunnel that hangs up mid-handshake is not a pass', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.hangUp);
    final AetherTrafficProof p =
        await AetherTrafficCheck.through(g.port, target: plain);
    await g.close();
    expect(p.carried, isFalse);
  });

  test('nothing listening is a failure, not a crash', () async {
    final ServerSocket g = await fakeGateway();
    final int dead = g.port;
    await g.close();
    final AetherTrafficProof p = await AetherTrafficCheck.through(dead,
        target: plain, budget: const Duration(seconds: 3));
    expect(p.carried, isFalse);
    expect(p.error, isNotNull);
  });

  // The finding this test exists for: `timeout` completes the outer future and
  // leaves the inner one running, so the read kept draining a socket nobody was
  // waiting for. Measured at 1.5GB resident inside a five second budget, still
  // climbing minutes after the call returned.
  test('an endless answer stops when the budget does', () async {
    final List<int> sent = <int>[0];
    final ServerSocket g =
        await fakeGateway(how: Behaviour.endless, sentCounter: sent);
    final Stopwatch clock = Stopwatch()..start();
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: 2));
    clock.stop();
    expect(p.carried, isFalse);
    expect(clock.elapsedMilliseconds, lessThan(4000),
        reason: 'the budget has to end the wait');

    // The real assertion. If the socket were still being drained the server
    // would still be writing, so the counter would keep climbing after the
    // caller gave up.
    final int atReturn = sent[0];
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final int later = sent[0];
    await g.close();
    expect(later - atReturn, lessThan(2 * 1024 * 1024),
        reason: 'the reader kept going after the budget expired: '
            'grew ${later - atReturn} bytes');
  });

  // Budget is deliberately generous here, so the deadline cannot be what stops
  // the read. Only the size cap can, which is what makes this a test of the cap
  // rather than a second test of the timeout.
  test('an answer bigger than the cap is cut short and still judged', () async {
    final List<int> sent = <int>[0];
    final ServerSocket g =
        await fakeGateway(how: Behaviour.huge, warp: 'on', sentCounter: sent);
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: 30));
    expect(p.carried, isTrue);
    expect(p.viaWarp, isTrue, reason: 'the trace is inside the first 16KB');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final int sentTotal = sent[0];
    await g.close();
    expect(sentTotal, lessThan(8 * 1024 * 1024),
        reason:
            'the whole body was read instead of the first ${AetherTrafficCheck.maxBody} '
            'bytes: server pushed $sentTotal');
  });

  test('a non-200 answer is not proof, whatever the body says', () async {
    final ServerSocket g =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    g.listen((Socket sock) async {
      final StreamIterator<List<int>> it = StreamIterator<List<int>>(sock);
      final List<int> buf = <int>[];
      Future<List<int>?> take(int n) async {
        while (buf.length < n) {
          if (!await it.moveNext()) return null;
          buf.addAll(it.current);
        }
        final List<int> o = buf.sublist(0, n);
        buf.removeRange(0, n);
        return o;
      }

      await take(3);
      sock.add(<int>[0x05, 0x00]);
      await sock.flush();
      await take(4);
      final int len = (await take(1))?.first ?? 0;
      await take(len + 2);
      sock.add(<int>[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await sock.flush();
      await take(1);
      // A captive portal or an injected error page that happens to contain a
      // warp line. Believing the body without the status made this proof.
      const String body = 'warp=on\nip=1.2.3.4\n';
      sock.add(utf8.encode('HTTP/1.1 403 Forbidden\r\n'
          'Content-Length: ${body.length}\r\n\r\n$body'));
      await sock.flush();
      await it.cancel();
      sock.destroy();
    });
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: 5));
    await g.close();
    expect(p.carried, isFalse);
    expect(p.viaWarp, isFalse);
    expect(p.error, contains('403'));
  });

  test('a spent budget reads as zero, not as a negative number', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.silent);
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: -3));
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, isNot(contains('-')));
  });

  // MUT E caught nothing until this existed: the size cap was ending the read
  // before the missing teardown could matter. Here the body never reaches the
  // cap, so if the deadline does not close the socket, nothing does.
  test('the budget closes the socket, it does not just stop waiting', () async {
    final List<bool> closed = <bool>[false];
    final ServerSocket g =
        await fakeGateway(how: Behaviour.dribble, clientClosed: closed);
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain, budget: const Duration(seconds: 2));
    expect(p.carried, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final bool sawClose = closed[0];
    await g.close();
    expect(sawClose, isTrue,
        reason: 'the far end never saw the connection close, so the read was '
            'still running after the budget expired');
  });

  test('cancelling stops the request instead of holding the tunnel', () async {
    final List<bool> closed = <bool>[false];
    bool cancelled = false;
    final ServerSocket g =
        await fakeGateway(how: Behaviour.dribble, clientClosed: closed);
    Timer(const Duration(milliseconds: 600), () => cancelled = true);
    final Stopwatch clock = Stopwatch()..start();
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        target: plain,
        budget: const Duration(seconds: 25),
        abort: () => cancelled);
    clock.stop();
    expect(p.carried, isFalse);
    // The budget is 25s. Returning anywhere near it means cancel did nothing.
    expect(clock.elapsedMilliseconds, lessThan(5000),
        reason: 'cancel did not interrupt the request');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final bool sawClose = closed[0];
    await g.close();
    expect(sawClose, isTrue, reason: 'the tunnel connection was left open');
  });
}
