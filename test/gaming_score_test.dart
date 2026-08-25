import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/speedtest/speed_test.dart';

void main() {
  group('latency curve, exactly as specified', () {
    test('the agreed thresholds', () {
      expect(GamingScore.latency(45), 100);
      expect(GamingScore.latency(60), 100);
      expect(GamingScore.latency(65), 98);
      expect(GamingScore.latency(75), 95);
      expect(GamingScore.latency(85), 90);
      expect(GamingScore.latency(95), 82);
      expect(GamingScore.latency(110), 70);
      expect(GamingScore.latency(140), 50);
      expect(GamingScore.latency(400), 25);
    });

    test('reaching Europe is not treated as a fault', () {
      // The whole point: an Iranian player on a European server sits around
      // 80ms and that is normal, not a bad connection.
      expect(GamingScore.latency(80), greaterThanOrEqualTo(95));
    });
  });

  group('the score follows stability, not distance', () {
    GamingResult build({
      required double median,
      required double p95,
      required double jitter,
      required double loss,
      int burst = 0,
    }) {
      final int l = GamingScore.latency(median);
      final int j = GamingScore.jitter(jitter);
      final int s = GamingScore.spike(p95 - median);
      final int p = GamingScore.loss(loss, burst);
      return GamingResult(
        samples: 100, received: 100,
        minMs: median, avgMs: median, medianMs: median, p95Ms: p95,
        maxMs: p95, jitterMs: jitter, lossPercent: loss,
        maxConsecutiveLoss: burst,
        latencyScore: l, jitterScore: j, spikeScore: s, lossScore: p,
        score: GamingScore.overall(
          latencyScore: l, jitterScore: j, spikeScore: s, lossScore: p),
      );
    }

    test('a steady far server beats a jumpy near one', () {
      final GamingResult farSteady =
          build(median: 120, p95: 128, jitter: 4, loss: 0);
      final GamingResult nearJumpy =
          build(median: 45, p95: 260, jitter: 40, loss: 1.5);
      expect(farSteady.score, greaterThan(nearJumpy.score));
    });

    test('a clean 80ms European line scores very well', () {
      final GamingResult r = build(median: 80, p95: 92, jitter: 6, loss: 0);
      expect(r.score, greaterThanOrEqualTo(90));
    });

    test('losses in a row cost more than the same losses spread out', () {
      final GamingResult spread =
          build(median: 80, p95: 92, jitter: 6, loss: 2, burst: 1);
      final GamingResult burst =
          build(median: 80, p95: 92, jitter: 6, loss: 2, burst: 5);
      expect(burst.score, lessThan(spread.score));
    });

    test('the spike is measured above the median, not absolutely', () {
      // 300ms that is always 300ms is steady; 60ms that reaches 300 is not.
      expect(GamingScore.spike(5), 100);
      expect(GamingScore.spike(240), 12);
    });
  });

  test('weights are the agreed ones and loss dominates', () {
    expect(GamingWeights.loss, 30);
    expect(GamingWeights.jitter, 25);
    expect(GamingWeights.spike, 20);
    expect(GamingWeights.latency, 15);
    // Stability carries three quarters of the judgement.
    final int stability =
        GamingWeights.loss + GamingWeights.jitter + GamingWeights.spike;
    expect(stability, greaterThan(GamingWeights.latency * 4));
    // Perfect components still read out of 100 despite the weights summing to 90.
    expect(
      GamingScore.overall(
          latencyScore: 100, jitterScore: 100, spikeScore: 100, lossScore: 100),
      100,
    );
  });
}
