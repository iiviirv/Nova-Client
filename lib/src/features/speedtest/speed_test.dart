import 'dart:async';

import 'package:http/http.dart' as http;

/// The outcome of one speed test: real throughput plus latency.
class SpeedResult {
  const SpeedResult({this.downMbps = 0, this.upMbps = 0, this.pingMs = 0});
  final double downMbps;
  final double upMbps;
  final int pingMs;
}

/// Measures REAL throughput over whatever the device currently routes through.
/// When Nova is connected, that is the active config's tunnel, so this is how a
/// user finds the fastest setup for their own line: the built-in urltest only
/// ranks latency, and the lowest-ping node is not always the highest-throughput
/// one (Reality vs Hysteria2+Brutal can tie on ping yet differ a lot on speed).
///
/// Download streams a payload from Cloudflare's public speed endpoint and times
/// it; upload POSTs a buffer. Not connected? It measures the direct line, still
/// a useful baseline.
class SpeedTest {
  SpeedTest({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => http.Client());

  final http.Client Function() _clientFactory;

  static const String _downUrl = 'https://speed.cloudflare.com/__down?bytes=';
  static const String _upUrl = 'https://speed.cloudflare.com/__up';

  /// Run ping -> download -> upload. [onDown]/[onUp] report live Mbps so the UI
  /// can animate. Each phase is time-boxed so a slow link still returns.
  Future<SpeedResult> run({
    void Function(double mbps)? onDown,
    void Function(double mbps)? onUp,
    Duration downTime = const Duration(seconds: 10),
    Duration upTime = const Duration(seconds: 8),
  }) async {
    final int ping = await _ping();
    final double down = await _download(onDown, downTime);
    final double up = await _upload(onUp, upTime);
    return SpeedResult(downMbps: down, upMbps: up, pingMs: ping);
  }

  Future<int> _ping() async {
    final http.Client c = _clientFactory();
    try {
      final Stopwatch sw = Stopwatch()..start();
      await c
          .get(Uri.parse('${_downUrl}0'))
          .timeout(const Duration(seconds: 8));
      return sw.elapsedMilliseconds;
    } catch (_) {
      return 0;
    } finally {
      c.close();
    }
  }

  /// Stream a large download and return the average Mbps. Stops at [max] or when
  /// the payload ends. Mbps = bits / microseconds (bits/us == Mbit/s).
  Future<double> _download(void Function(double)? onProgress, Duration max) async {
    final http.Client c = _clientFactory();
    try {
      // 200 MB cap; the time-box below ends it well before that on a fast line.
      final http.Request req =
          http.Request('GET', Uri.parse('${_downUrl}209715200'));
      final http.StreamedResponse resp =
          await c.send(req).timeout(const Duration(seconds: 10));
      int bytes = 0;
      final Stopwatch sw = Stopwatch()..start();
      final Completer<void> done = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      sub = resp.stream.listen(
        (List<int> chunk) {
          bytes += chunk.length;
          final int us = sw.elapsedMicroseconds;
          if (us > 0) onProgress?.call(bytes * 8 / us);
          if (sw.elapsed >= max) {
            sub.cancel();
            finish();
          }
        },
        onDone: finish,
        onError: (_) => finish(),
        cancelOnError: true,
      );
      await done.future;
      final int us = sw.elapsedMicroseconds;
      return us > 0 ? bytes * 8 / us : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close();
    }
  }

  /// POST a growing buffer and return the average Mbps. Time-boxed by [max].
  Future<double> _upload(void Function(double)? onProgress, Duration max) async {
    final http.Client c = _clientFactory();
    try {
      final Stopwatch sw = Stopwatch()..start();
      int sent = 0;
      // Emit ~1 MB chunks until the time box elapses; report live Mbps.
      final List<int> chunk = List<int>.filled(1024 * 1024, 65);
      Stream<List<int>> body() async* {
        while (sw.elapsed < max) {
          yield chunk;
          sent += chunk.length;
          final int us = sw.elapsedMicroseconds;
          if (us > 0) onProgress?.call(sent * 8 / us);
          // Let the socket drain; without a yield the generator can starve I/O.
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      final http.StreamedRequest req =
          http.StreamedRequest('POST', Uri.parse(_upUrl));
      req.headers['content-type'] = 'application/octet-stream';
      // Pump the body into the request, then close it.
      unawaited(() async {
        await for (final List<int> c in body()) {
          req.sink.add(c);
        }
        await req.sink.close();
      }());
      await c.send(req).timeout(max + const Duration(seconds: 4));
      final int us = sw.elapsedMicroseconds;
      return us > 0 ? sent * 8 / us : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close();
    }
  }
}
