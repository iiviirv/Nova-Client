import 'dart:async';
import 'dart:io';

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

  /// The ceiling on one transfer, not the target.
  ///
  /// A fixed 8 MB was the original plan and it is wrong at both ends of the
  /// range. On a 785 Mbit line 8 MB is over in 80ms, and after the warm-up that
  /// leaves about 70ms of traffic to divide by: TCP has barely opened its
  /// window, so the line read 330 against Cloudflare's 785 on the same phone a
  /// minute apart. Size cannot be the stopping condition when the whole point is
  /// to reach a steady state first.
  ///
  /// 64 MB and not more: speed.cloudflare.com answers 403 to a `bytes=` above
  /// roughly 100 MB, and a refusal is indistinguishable from a very fast, very
  /// short transfer unless the status is checked. Measured: 64 MB returns 200,
  /// 100 MB returns 403.
  static const int kMaxPayloadBytes = 64 * 1024 * 1024;

  /// How long to stay in the steady state before reporting.
  ///
  /// This is the real stopping condition. Three seconds is long enough for the
  /// congestion window to open on a fast line and short enough that nobody is
  /// left waiting; a slow line ends earlier by hitting the payload ceiling.
  static const Duration kMeasureFor = Duration(seconds: 3);

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
          await c.getUrl(Uri.parse('$_down$kMaxPayloadBytes'));
      final HttpClientResponse resp = await req.close();
      // A refused request delivers a one-byte body in a millisecond, which
      // would otherwise sail through the arithmetic below as a real reading.
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return 0;
      }

      int total = 0;
      // Timing starts only once the warm-up bytes are past, and counts only what
      // arrives after that, so the congestion window's ramp is excluded from
      // both halves of the division.
      int measured = 0;
      final Stopwatch sw = Stopwatch();
      final Completer<void> done = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      sub = resp.listen(
        (List<int> chunk) {
          total += chunk.length;
          if (total < kWarmupBytes) return;
          if (!sw.isRunning) {
            sw.start();
            return;
          }
          measured += chunk.length;
          final int us = sw.elapsedMicroseconds;
          if (us > 0) onProgress?.call(measured * 8 / us);
          // Enough steady state to be a measurement. Stopping on time rather
          // than on size is what lets one code path serve a 5 Mbit line and a
          // 785 Mbit one.
          if (sw.elapsed >= kMeasureFor) {
            unawaited(sub.cancel());
            finish();
          }
        },
        onDone: finish,
        onError: (Object _) => finish(),
        cancelOnError: true,
      );
      await done.future;
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
  /// Two things make this honest, and it took both.
  ///
  /// Every chunk is flushed before the next is counted. The original version
  /// added each chunk to a buffered sink and counted it as sent, so it timed how
  /// fast Dart fills memory: 3345 Mbit/s on an 80 Mbit line.
  ///
  /// And the clock stops when the SERVER answers, not when the last flush
  /// returns. A flush only means the kernel took the bytes, and on a fast link
  /// its send buffer can still be holding megabytes that are not on the wire, so
  /// stopping at the last flush still over-reports: on an iPhone it claimed
  /// 578 Mbit/s up on a line whose download measured 453. The response to a POST
  /// cannot arrive until the far end has received the whole body, so waiting for
  /// it bounds the transfer honestly. It costs one round trip, which on an 8 MB
  /// transfer is noise.
  Future<double> measureUpload(void Function(double)? onProgress) async {
    final HttpClient c = _clientFactory();
    try {
      final HttpClientRequest req = await c.postUrl(Uri.parse(_up));
      req.headers.contentType = ContentType.binary;
      // No content length: the body is chunked so the transfer can stop on time
      // rather than on a size decided before the speed is known.
      // 1 MB, not 64 KB. Every chunk is followed by an awaited flush, and each
      // of those is a trip through the event loop; at 64 KB that is a thousand
      // round trips per transfer and the flush rate, not the line, became the
      // ceiling. Correctness does not need the small chunk: the clock stops when
      // the server answers, which cannot happen until it has the whole body.
      const int chunkSize = 1024 * 1024;
      final List<int> chunk = List<int>.filled(chunkSize, 65);
      int total = 0;
      int measured = 0;
      final Stopwatch sw = Stopwatch();

      while (total < kMaxPayloadBytes) {
        req.add(chunk);
        await req.flush();
        total += chunkSize;
        if (total >= kWarmupBytes) {
          if (!sw.isRunning) {
            sw.start();
          } else {
            measured += chunkSize;
          }
          final int us = sw.elapsedMicroseconds;
          if (us > 0 && measured > 0) onProgress?.call(measured * 8 / us);
          if (sw.elapsed >= kMeasureFor) break;
        }
      }
      // The far end has the whole body only once it answers; that is the end of
      // the transfer, and anything still sitting in a send buffer is counted.
      await req.close().then((HttpClientResponse r) => r.drain<void>());
      sw.stop();
      final int us = sw.elapsedMicroseconds;
      return us > 0 && measured > 0 ? measured * 8 / us : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close(force: true);
    }
  }
}
