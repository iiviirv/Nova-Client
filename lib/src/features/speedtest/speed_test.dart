import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// The outcome of one speed test.
///
/// Throughput is steady-state Mbit/s, latency is an average over many probes,
/// and [jitterMs] / [lossPercent] are what actually decide whether a config is
/// usable for a game: a 40ms line that jitters 60ms or drops 3% of requests is
/// worse to play on than a steady 90ms one.
class SpeedResult {
  const SpeedResult({
    this.downMbps = 0,
    this.upMbps = 0,
    this.pingMs = 0,
    this.jitterMs = 0,
    this.lossPercent = 0,
    this.probesSent = 0,
  });

  final double downMbps;
  final double upMbps;

  /// Mean round trip over [SpeedTest.kLatencyProbes] probes, in ms.
  final int pingMs;

  /// Mean deviation between consecutive round trips, in ms. This is the RFC 3550
  /// sense of jitter: how much the latency moves, not how large it is.
  final double jitterMs;

  /// Share of probes that never came back, as a percentage (1.00 means 1.00 %).
  final double lossPercent;

  /// How many probes the loss figure is based on, so the UI can say "of 1000"
  /// rather than implying more precision than was measured.
  final int probesSent;

  bool get isEmpty => downMbps == 0 && upMbps == 0 && pingMs == 0;
}

/// Measures REAL throughput and line quality over whatever the device currently
/// routes through. Connected, that is the active config's tunnel, so this is how
/// a user finds the best setup for their own line: the lightning test only ranks
/// latency, and the lowest-ping node is not always the best one to play on.
///
/// Everything here is deliberately sequential. Download and upload are never in
/// flight at once: they share one line, so measuring them together measures
/// neither, and it was reporting a 200 Mbit line as 0.6 down.
class SpeedTest {
  SpeedTest({
    HttpClient Function()? clientFactory,
    String? downUrl,
    String? upUrl,
  })  : _clientFactory = clientFactory ?? _defaultClient,
        _down = downUrl ?? _downUrl,
        _up = upUrl ?? _upUrl;

  final HttpClient Function() _clientFactory;

  /// Overridable so the tests can point at a loopback server and measure the
  /// real code path instead of a mock of it.
  final String _down;
  final String _up;

  static HttpClient _defaultClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);

  static const String _downUrl = 'https://speed.cloudflare.com/__down?bytes=';
  static const String _upUrl = 'https://speed.cloudflare.com/__up';

  /// One transfer each way. Big enough that the steady-state window below is a
  /// real measurement rather than a rounding error, small enough that someone on
  /// a slow line is not stuck here for a minute.
  static const int kPayloadBytes = 8 * 1024 * 1024;

  /// Probes behind the latency and jitter figures. Twenty is enough for a stable
  /// mean without making the user wait.
  static const int kLatencyProbes = 20;

  /// Probes behind the loss figure.
  static const int kLossProbes = 1000;

  /// A probe that has not answered in this long is counted as lost. Generous on
  /// purpose: this is loss, not slowness, and slowness is what jitter reports.
  static const Duration kProbeTimeout = Duration(seconds: 4);

  /// Ignore this much of each transfer before timing starts.
  ///
  /// TCP opens its congestion window gradually, so the first megabyte of any
  /// transfer is slower than the line. Averaging it in is what made a fast line
  /// read slow. The reported figure is the rate over what came after.
  static const int kWarmupBytes = 1024 * 1024;

  /// Latency and jitter, then loss, then download, then upload. Each phase runs
  /// alone. [onDown] and [onUp] report live Mbit/s for the dial; the returned
  /// figures are the steady-state ones and can differ from the last live value.
  Future<SpeedResult> run({
    void Function(double mbps)? onDown,
    void Function(double mbps)? onUp,
    void Function(String phase)? onPhase,
    bool measureLoss = true,
  }) async {
    onPhase?.call('latency');
    final ({int avgMs, double jitterMs}) l = await measureLatency();

    double loss = 0;
    int probes = 0;
    if (measureLoss) {
      onPhase?.call('loss');
      final ({double percent, int sent}) r = await measureLoss_();
      loss = r.percent;
      probes = r.sent;
    }

    onPhase?.call('download');
    final double down = await measureDownload(onDown);

    // Let the line settle before the other direction, so the upload does not
    // start inside the download's fading congestion window.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    onPhase?.call('upload');
    final double up = await measureUpload(onUp);

    return SpeedResult(
      downMbps: down,
      upMbps: up,
      pingMs: l.avgMs,
      jitterMs: l.jitterMs,
      lossPercent: loss,
      probesSent: probes,
    );
  }

  /// Mean round trip and jitter over [kLatencyProbes] probes on ONE reused
  /// connection.
  ///
  /// The old version timed a single cold request, so DNS, the TCP handshake and
  /// the TLS handshake all landed in the number: it reported 327ms on a line
  /// whose real round trip was 111ms. Keeping the connection alive and probing
  /// it repeatedly measures the round trip and nothing else.
  Future<({int avgMs, double jitterMs})> measureLatency() async {
    final HttpClient c = _clientFactory();
    final List<double> rtt = <double>[];
    try {
      final Uri u = Uri.parse('${_down}0');
      // One throwaway request opens the connection; its cost is setup, not
      // latency, so it is not recorded.
      await _probe(c, u);
      for (int i = 0; i < kLatencyProbes; i++) {
        final double? ms = await _probe(c, u);
        if (ms != null) rtt.add(ms);
      }
    } catch (_) {
      // Fall through with whatever was collected.
    } finally {
      c.close(force: true);
    }
    if (rtt.isEmpty) return (avgMs: 0, jitterMs: 0.0);
    final double avg = rtt.reduce((double a, double b) => a + b) / rtt.length;
    // RFC 3550's sense: the mean absolute difference between consecutive
    // round trips, which is what a game feels, rather than the spread about the
    // mean.
    double jitter = 0;
    for (int i = 1; i < rtt.length; i++) {
      jitter += (rtt[i] - rtt[i - 1]).abs();
    }
    if (rtt.length > 1) jitter /= rtt.length - 1;
    return (avgMs: avg.round(), jitterMs: jitter);
  }

  /// Share of [kLossProbes] probes that never answered, as a percentage.
  ///
  /// A caveat worth knowing when reading this number: a userspace app cannot
  /// send ICMP or see the wire, and everything here rides TCP through the
  /// tunnel, where the kernel retransmits a lost segment without telling us. So
  /// this is the share of REQUESTS that failed or timed out, not true per-packet
  /// loss. On a clean line it reads 0.00 %; when it climbs, something on the
  /// path really is dropping traffic, which is the signal that matters.
  Future<({double percent, int sent})> measureLoss_() async {
    final HttpClient c = _clientFactory();
    final Uri u = Uri.parse('${_down}0');
    int lost = 0;
    int sent = 0;
    try {
      // A small amount of concurrency, or a thousand sequential round trips on
      // a 100ms line would take nearly two minutes.
      const int lanes = 8;
      final int each = kLossProbes ~/ lanes;
      Future<void> lane() async {
        for (int i = 0; i < each; i++) {
          sent++;
          final double? ms = await _probe(c, u);
          if (ms == null) lost++;
        }
      }

      await Future.wait(<Future<void>>[
        for (int i = 0; i < lanes; i++) lane(),
      ]);
    } catch (_) {
      // Keep whatever was counted.
    } finally {
      c.close(force: true);
    }
    if (sent == 0) return (percent: 0.0, sent: 0);
    return (percent: lost * 100 / sent, sent: sent);
  }

  /// One round trip in ms, or null when it did not come back.
  Future<double?> _probe(HttpClient c, Uri u) async {
    try {
      final Stopwatch sw = Stopwatch()..start();
      final HttpClientRequest req = await c.getUrl(u).timeout(kProbeTimeout);
      final HttpClientResponse resp = await req.close().timeout(kProbeTimeout);
      await resp.drain<void>().timeout(kProbeTimeout);
      return sw.elapsedMicroseconds / 1000.0;
    } catch (_) {
      return null;
    }
  }

  /// Download [kPayloadBytes] and return the steady-state Mbit/s.
  Future<double> measureDownload(void Function(double)? onProgress) async {
    final HttpClient c = _clientFactory();
    try {
      final HttpClientRequest req =
          await c.getUrl(Uri.parse('$_down$kPayloadBytes'));
      final HttpClientResponse resp = await req.close();

      int total = 0;
      // Timing starts only once the warm-up bytes are past, and counts only what
      // arrives after that, so the congestion window's ramp is excluded from
      // both halves of the division.
      int measured = 0;
      final Stopwatch sw = Stopwatch();
      await for (final List<int> chunk in resp) {
        total += chunk.length;
        if (total >= kWarmupBytes) {
          if (!sw.isRunning) {
            sw.start();
          } else {
            measured += chunk.length;
          }
          final int us = sw.elapsedMicroseconds;
          if (us > 0 && measured > 0) onProgress?.call(measured * 8 / us);
        }
      }
      final int us = sw.elapsedMicroseconds;
      return us > 0 && measured > 0 ? measured * 8 / us : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close(force: true);
    }
  }

  /// Upload [kPayloadBytes] and return the steady-state Mbit/s.
  ///
  /// Every chunk is flushed before the next is counted. The old version added
  /// each chunk to a buffered sink and counted it as sent, so it timed how fast
  /// Dart fills memory: it reported 3345 Mbit/s on an 80 Mbit line. Waiting for
  /// the flush means the count tracks what the socket actually accepted.
  Future<double> measureUpload(void Function(double)? onProgress) async {
    final HttpClient c = _clientFactory();
    try {
      final HttpClientRequest req = await c.postUrl(Uri.parse(_up));
      req.headers.contentType = ContentType.binary;
      req.contentLength = kPayloadBytes;

      const int chunkSize = 64 * 1024;
      final List<int> chunk = List<int>.filled(chunkSize, 65);
      int total = 0;
      int measured = 0;
      final Stopwatch sw = Stopwatch();

      while (total < kPayloadBytes) {
        final int n = math.min(chunkSize, kPayloadBytes - total);
        req.add(n == chunkSize ? chunk : chunk.sublist(0, n));
        await req.flush();
        total += n;
        if (total >= kWarmupBytes) {
          if (!sw.isRunning) {
            sw.start();
          } else {
            measured += n;
          }
          final int us = sw.elapsedMicroseconds;
          if (us > 0 && measured > 0) onProgress?.call(measured * 8 / us);
        }
      }
      final int us = sw.elapsedMicroseconds;
      // Close and read the response so the server's ack is part of the exchange
      // rather than left dangling, but do not count that time as transfer.
      await req.close().then((HttpClientResponse r) => r.drain<void>());
      return us > 0 && measured > 0 ? measured * 8 / us : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close(force: true);
    }
  }
}
