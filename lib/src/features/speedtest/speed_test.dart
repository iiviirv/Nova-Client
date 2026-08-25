import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

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


/// How playable a connection is, judged the way a player experiences it.
///
/// Deliberately NOT a latency score. An Iranian player is reaching European
/// servers, so 80 to 100ms is the normal, expected cost of the distance and
/// nobody is surprised by it. What ruins a game at that distance is the
/// connection moving around: a frame that arrives 200ms late after a run of
/// 80ms ones, or four packets in a row that never arrive at all. So stability
/// carries 75 of the 90 weight and raw latency carries 15.
@immutable
class GamingResult {
  const GamingResult({
    required this.samples,
    required this.received,
    required this.minMs,
    required this.avgMs,
    required this.medianMs,
    required this.p95Ms,
    required this.maxMs,
    required this.jitterMs,
    required this.lossPercent,
    required this.maxConsecutiveLoss,
    required this.latencyScore,
    required this.jitterScore,
    required this.spikeScore,
    required this.lossScore,
    required this.score,
  });

  final int samples;
  final int received;

  final double minMs;
  final double avgMs;
  final double medianMs;

  /// The 95th percentile: what the worst one frame in twenty looks like. This is
  /// the number a player feels as "it spiked", and an average hides it entirely.
  final double p95Ms;
  final double maxMs;

  /// Mean change between consecutive round trips (RFC 3550's sense).
  final double jitterMs;

  final double lossPercent;

  /// The longest run of probes that went unanswered back to back.
  ///
  /// Ten losses spread through a match is a bad connection; ten in a row is a
  /// freeze, a rubber-band and possibly a disconnect. The percentage cannot tell
  /// those apart, so this is reported beside it.
  final int maxConsecutiveLoss;

  /// The four component scores, 0 to 100, before weighting.
  final int latencyScore;
  final int jitterScore;
  final int spikeScore;
  final int lossScore;

  /// The weighted total, 0 to 100.
  final int score;

  /// How far above the median the slow one-in-twenty sits. The spike itself,
  /// separated from how far away the server is.
  double get spikeMs => (p95Ms - medianMs).clamp(0, double.infinity);

  bool get isEmpty => samples == 0;
}

/// The weights, as agreed: loss hurts most, then jitter, then spikes, and raw
/// latency least. They sum to 90 rather than 100 on purpose; the total is scaled
/// back up so the result still reads out of 100.
class GamingWeights {
  const GamingWeights._();
  static const int loss = 30;
  static const int jitter = 25;
  static const int spike = 20;
  static const int latency = 15;
  static const int total = loss + jitter + spike + latency;
}

/// Scoring curves. Separated out so they can be tested and argued with directly
/// rather than being buried in a measurement.
class GamingScore {
  const GamingScore._();

  /// Latency, exactly as specified. Generous by design up to about 100ms,
  /// because that is simply what reaching Europe costs from Iran and it is not a
  /// fault of the connection.
  static int latency(double ms) {
    if (ms <= 60) return 100;
    if (ms <= 70) return 98;
    if (ms <= 80) return 95;
    if (ms <= 90) return 90;
    if (ms <= 100) return 82;
    if (ms <= 120) return 70;
    if (ms <= 150) return 50;
    return 25;
  }

  /// Jitter. Tighter than the latency curve on purpose: at 80ms of distance,
  /// what a player notices is the movement, not the distance.
  static int jitter(double ms) {
    if (ms <= 5) return 100;
    if (ms <= 10) return 92;
    if (ms <= 15) return 85;
    if (ms <= 20) return 75;
    if (ms <= 30) return 60;
    if (ms <= 50) return 40;
    return 20;
  }

  /// The spike, measured as how far the 95th percentile sits ABOVE the median
  /// rather than as an absolute figure. A steady 120ms line scores well here; a
  /// 60ms line that jumps to 300 does not, which is the right way round.
  static int spike(double aboveMedianMs) {
    if (aboveMedianMs <= 10) return 100;
    if (aboveMedianMs <= 20) return 90;
    if (aboveMedianMs <= 35) return 78;
    if (aboveMedianMs <= 50) return 62;
    if (aboveMedianMs <= 80) return 45;
    if (aboveMedianMs <= 120) return 28;
    return 12;
  }

  /// Loss, with the burst taken into account.
  ///
  /// The percentage alone is not enough: the same 2% is a minor annoyance spread
  /// out and a visible freeze if it arrives in one run. So a base score comes
  /// from the percentage and consecutive losses take it down from there.
  static int loss(double percent, int maxConsecutive) {
    int base;
    if (percent <= 0) {
      base = 100;
    } else if (percent <= 0.5) {
      base = 90;
    } else if (percent <= 1) {
      base = 75;
    } else if (percent <= 2) {
      base = 55;
    } else if (percent <= 5) {
      base = 30;
    } else {
      base = 10;
    }
    // Two in a row is a stutter, three is a rubber-band, five or more is the
    // game deciding you left.
    final int burst = switch (maxConsecutive) {
      0 || 1 => 0,
      2 => 10,
      3 => 20,
      4 => 30,
      _ => 45,
    };
    return (base - burst).clamp(0, 100);
  }

  /// The weighted total, scaled to 100.
  static int overall({
    required int latencyScore,
    required int jitterScore,
    required int spikeScore,
    required int lossScore,
  }) {
    final int weighted = lossScore * GamingWeights.loss +
        jitterScore * GamingWeights.jitter +
        spikeScore * GamingWeights.spike +
        latencyScore * GamingWeights.latency;
    return (weighted / GamingWeights.total).round().clamp(0, 100);
  }
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

  /// Probes behind the gaming test.
  ///
  /// Twenty is enough for an average and nowhere near enough for a 95th
  /// percentile: one slow frame in twenty IS the 95th percentile, so the figure
  /// would be whatever the single worst sample happened to be. A hundred puts
  /// five samples in that tail, which is the least that can be called a
  /// measurement.
  static const int kGamingProbes = 100;

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

  /// The gaming test: one long, strictly sequential run of probes, reported as
  /// a distribution rather than an average, and scored for playability.
  ///
  /// Sequential on purpose, where the loss test runs eight lanes at once. Lanes
  /// are fine for "what fraction failed" and useless for "how many failed in a
  /// row", because concurrent probes have no order to be consecutive in. A run
  /// of losses is exactly what a player feels as a freeze, so the probes go one
  /// after another on one kept-alive connection, which is also the closest this
  /// can get to how a game's own traffic behaves.
  Future<GamingResult> measureGaming({
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final HttpClient c = _clientFactory();
    final List<double> rtt = <double>[];
    int sent = 0;
    int lost = 0;
    int worstRun = 0;
    int run = 0;
    try {
      final Uri u = Uri.parse('${_down}0');
      // One throwaway to open the connection; its cost is setup, not latency.
      await _probe(c, u);
      for (int i = 0; i < kGamingProbes; i++) {
        if (cancelled?.call() ?? false) break;
        sent++;
        final double? ms = await _probe(c, u);
        if (ms == null) {
          lost++;
          run++;
          if (run > worstRun) worstRun = run;
        } else {
          run = 0;
          rtt.add(ms);
        }
        onProgress?.call(i + 1, kGamingProbes);
      }
    } catch (_) {
      // Keep whatever was collected; a short run still describes the line.
    } finally {
      c.close(force: true);
    }

    if (rtt.isEmpty) {
      return GamingResult(
        samples: sent,
        received: 0,
        minMs: 0,
        avgMs: 0,
        medianMs: 0,
        p95Ms: 0,
        maxMs: 0,
        jitterMs: 0,
        lossPercent: sent == 0 ? 0 : 100,
        maxConsecutiveLoss: worstRun,
        latencyScore: 0,
        jitterScore: 0,
        spikeScore: 0,
        lossScore: 0,
        score: 0,
      );
    }

    // Jitter is taken over the ORDER the probes came back in, so it has to be
    // computed before sorting.
    double jitter = 0;
    for (int i = 1; i < rtt.length; i++) {
      jitter += (rtt[i] - rtt[i - 1]).abs();
    }
    if (rtt.length > 1) jitter /= rtt.length - 1;

    final List<double> sorted = <double>[...rtt]..sort();
    final double avg = sorted.reduce((double a, double b) => a + b) / sorted.length;
    final double median = _percentile(sorted, 0.50);
    final double p95 = _percentile(sorted, 0.95);
    final double lossPct = sent == 0 ? 0 : lost * 100 / sent;

    final int latencyScore = GamingScore.latency(median);
    final int jitterScore = GamingScore.jitter(jitter);
    final double above = p95 - median;
    final int spikeScore = GamingScore.spike(above < 0 ? 0 : above);
    final int lossScore = GamingScore.loss(lossPct, worstRun);

    return GamingResult(
      samples: sent,
      received: rtt.length,
      minMs: sorted.first,
      avgMs: avg,
      medianMs: median,
      p95Ms: p95,
      maxMs: sorted.last,
      jitterMs: jitter,
      lossPercent: lossPct,
      maxConsecutiveLoss: worstRun,
      latencyScore: latencyScore,
      jitterScore: jitterScore,
      spikeScore: spikeScore,
      lossScore: lossScore,
      score: GamingScore.overall(
        latencyScore: latencyScore,
        jitterScore: jitterScore,
        spikeScore: spikeScore,
        lossScore: lossScore,
      ),
    );
  }

  /// Nearest-rank percentile over an already-sorted list.
  static double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final int rank = (q * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
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
