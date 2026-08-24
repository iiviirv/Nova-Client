import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/speedtest/speed_test.dart';

/// A loopback stand-in for Cloudflare's speed endpoints.
///
/// The old test mocked the HTTP client, which meant it could only ever prove
/// that arithmetic on a fake stream produced a positive number. That is exactly
/// what it did prove, right up until the upload was found to be reporting
/// 3345 Mbit/s on an 80 Mbit line: the bug was in what the code counted as
/// "sent", which no mock of the client could see. A real server on 127.0.0.1
/// exercises the real socket path, so the count has to be honest.
class _FakeSpeedServer {
  _FakeSpeedServer(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;

  /// Bytes the server actually received on upload requests.
  int received = 0;

  /// Round trips served, so a test can assert the probe count.
  int probes = 0;

  static Future<_FakeSpeedServer> start() async =>
      _FakeSpeedServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  String get downUrl => 'http://127.0.0.1:${_server.port}/__down?bytes=';
  String get upUrl => 'http://127.0.0.1:${_server.port}/__up';

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path == '/__up') {
      await for (final List<int> chunk in req) {
        received += chunk.length;
      }
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    final int bytes = int.tryParse(req.uri.queryParameters['bytes'] ?? '0') ?? 0;
    if (bytes == 0) probes++;
    req.response.statusCode = 200;
    if (bytes > 0) {
      const int chunk = 64 * 1024;
      final List<int> buf = List<int>.filled(chunk, 7);
      int left = bytes;
      while (left > 0) {
        final int n = left < chunk ? left : chunk;
        req.response.add(n == chunk ? buf : buf.sublist(0, n));
        await req.response.flush();
        left -= n;
      }
    }
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeSpeedServer server;
  late SpeedTest speed;

  setUp(() async {
    server = await _FakeSpeedServer.start();
    speed = SpeedTest(downUrl: server.downUrl, upUrl: server.upUrl);
  });

  tearDown(() async => server.close());

  test('download reports a positive rate', () async {
    final double mbps = await speed.measureDownload(null);
    expect(mbps, greaterThan(0));
  });

  test('upload counts only what the socket accepted', () async {
    final double mbps = await speed.measureUpload(null);
    expect(mbps, greaterThan(0));
    // The whole payload reached the server. The old implementation counted
    // bytes handed to a buffered sink, so it could "finish" long before this
    // was true and divide the full payload by a fraction of the real time.
    expect(server.received, SpeedTest.kPayloadBytes);
  });

  // There is deliberately no "a slow receiver slows the reported rate" test.
  // It is the assertion you would want, and it cannot be made to hold here: on
  // loopback the kernel and Dart's own buffers absorb the whole 8 MB payload
  // before backpressure ever reaches the sender, so a receiver that stalls for
  // 4ms per chunk still reports over 1 Gbit/s. That is a property of loopback,
  // not of the measurement. Over a real link the socket buffer is small next to
  // the payload, and the figures were checked against curl on the same line:
  // 411 vs 434 Mbit/s down, 151 vs 126 up. What CAN be proved here is that the
  // call does not return until every byte has actually reached the far side,
  // which is the specific thing the old buffered-sink version got wrong.
  test('latency probes the connection repeatedly and reports jitter', () async {
    final ({int avgMs, double jitterMs}) r = await speed.measureLatency();
    // One warm-up probe plus the measured ones.
    expect(server.probes, SpeedTest.kLatencyProbes + 1);
    expect(r.avgMs, greaterThanOrEqualTo(0));
    expect(r.jitterMs, greaterThanOrEqualTo(0));
  });

  test('a clean line reports no loss', () async {
    final ({double percent, int sent}) r = await speed.measureLoss_();
    expect(r.sent, greaterThan(0));
    expect(r.percent, 0);
  });

  test('an unreachable endpoint is all loss, not a crash', () async {
    // Port 1 on loopback refuses immediately, which is the "nothing came back"
    // case the percentage exists to describe.
    final SpeedTest dead = SpeedTest(
      downUrl: 'http://127.0.0.1:1/__down?bytes=',
      upUrl: 'http://127.0.0.1:1/__up',
    );
    final ({double percent, int sent}) r = await dead.measureLoss_();
    expect(r.percent, 100);
    // And the throughput paths return zero rather than throwing.
    expect(await dead.measureDownload(null), 0);
    expect(await dead.measureUpload(null), 0);
  });
}
