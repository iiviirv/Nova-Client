import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_traffic_check.dart';

/// How the fake gateway behaves.
enum Behaviour { serve, refuse, notSocks, silent, hangUp }

/// A stand-in for the tunnel's SOCKS5 port.
///
/// The real thing needs the native core and a route to Cloudflare, so the
/// interesting failures (a refusal, a silent proxy, a leak around the tunnel)
/// could otherwise only be seen by breaking someone's network. Here they are
/// just a switch.
Future<ServerSocket> fakeGateway({
  Behaviour how = Behaviour.serve,
  String warp = 'on',
  String ip = '104.28.208.123',
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
      sock.add(<int>[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
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
      sock.add(utf8.encode('HTTP/1.1 200 OK\r\n'
          'Content-Type: text/plain\r\n'
          'Content-Length: ${body.length}\r\n\r\n$body'));
      await sock.flush();
    } finally {
      await it.cancel();
      sock.destroy();
    }
  });
  return server;
}

void main() {
  test('a tunnel that carries traffic through WARP passes', () async {
    final ServerSocket g = await fakeGateway(warp: 'on');
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.carried, isTrue);
    expect(p.viaWarp, isTrue);
    expect(p.warp, 'on');
    expect(p.ip, '104.28.208.123');
  });

  test('warp=plus is WARP too', () async {
    final ServerSocket g = await fakeGateway(warp: 'plus');
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.viaWarp, isTrue);
  });

  // The failure the core's own check cannot see. A request that escaped around
  // the tunnel still answers 200, and calling that a working gateway would save
  // an endpoint that proves nothing.
  test('traffic that leaked around the tunnel is not a pass', () async {
    final ServerSocket g = await fakeGateway(warp: 'off');
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.carried, isTrue, reason: 'bytes did move');
    expect(p.viaWarp, isFalse, reason: 'but not through WARP');
  });

  test('a refused connection says so rather than timing out', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.refuse);
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, contains('refused'));
  });

  test('a port that is not SOCKS5 is reported as such', () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.notSocks);
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.carried, isFalse);
    expect(p.error, contains('SOCKS5'));
  });

  test('a proxy that accepts and then goes quiet is bounded by the budget',
      () async {
    final ServerSocket g = await fakeGateway(how: Behaviour.silent);
    final Stopwatch clock = Stopwatch()..start();
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port,
        budget: const Duration(seconds: 2));
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
    final AetherTrafficProof p = await AetherTrafficCheck.through(g.port);
    await g.close();
    expect(p.carried, isFalse);
  });

  test('nothing listening is a failure, not a crash', () async {
    final ServerSocket g = await fakeGateway();
    final int dead = g.port;
    await g.close();
    final AetherTrafficProof p = await AetherTrafficCheck.through(dead,
        budget: const Duration(seconds: 3));
    expect(p.carried, isFalse);
    expect(p.error, isNotNull);
  });
}
