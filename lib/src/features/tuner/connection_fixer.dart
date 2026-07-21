import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/proxy/proxy_controller.dart';
import '../settings/settings_controller.dart';

/// One candidate's measured outcome.
class FixResult {
  const FixResult({
    required this.fingerprint,
    required this.reachable,
    required this.latencyMs,
  });

  final String fingerprint;

  /// Whether a request actually completed through the tunnel on this fingerprint.
  final bool reachable;

  /// Reach latency in ms (a rough quality signal among the ones that work).
  /// 0 when unreachable.
  final int latencyMs;
}

/// Live progress so the UI can show "Testing Firefox (2 of 5)" and fill in each
/// result as it lands.
class FixProgress {
  const FixProgress({
    required this.index,
    required this.total,
    required this.fingerprint,
    required this.phase,
    this.result,
  });

  final int index; // 0-based
  final int total;
  final String fingerprint;

  /// 'connecting' | 'probing' | 'result' | 'applying'.
  final String phase;

  /// Set when [phase] == 'result': this candidate's measured outcome.
  final FixResult? result;
}

/// The final ranked outcome.
class FixOutcome {
  const FixOutcome({
    required this.success,
    this.best,
    this.results = const <FixResult>[],
    this.cancelled = false,
  });

  final bool success;

  /// The winning fingerprint (already applied + persisted, tunnel left on it).
  final String? best;

  /// Every candidate's result, ranked best-first (reachable then lowest latency).
  final List<FixResult> results;
  final bool cancelled;
}

/// "Find a working setup": when a user can't get past the DPI, this TESTS each
/// anti-censorship fingerprint on their real network, measuring which actually
/// carry traffic and how fast, then applies the best one. It only makes sense
/// when the user is already stuck, so cycling the tunnel is acceptable. Because
/// it tests every candidate (connect + reach check each) it takes a couple of
/// minutes; the UI must say so up front.
///
/// Client-only: nothing touches the Cloudflare worker, so it can't affect the
/// free plan's request budget.
class ConnectionFixer {
  ConnectionFixer(this._proxy, this._settings);

  final ProxyController _proxy;
  final SettingsController _settings;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  /// The fingerprints to test, ordered by prior likelihood (randomized first).
  /// Fragmentation stays on (the app default), so only the fingerprint varies.
  static const List<String> candidates = <String>[
    'randomized',
    'chrome',
    'firefox',
    'safari',
    'edge',
  ];

  /// Rough time to show the user up front: one connect+probe per candidate plus
  /// a final reconnect onto the winner.
  static Duration get estimated =>
      Duration(seconds: (candidates.length + 1) * _perAttemptSeconds);
  static const int _perAttemptSeconds = 26;

  /// Test every candidate, then apply the best (reachable + lowest latency) and
  /// leave the tunnel connected on it. If none reach, the user's original
  /// fingerprint is restored and [FixOutcome.success] is false.
  Future<FixOutcome> run({void Function(FixProgress)? onProgress}) async {
    _cancelled = false;
    final String original = _settings.fingerprint;
    final List<FixResult> results = <FixResult>[];
    try {
      if (_proxy.state.isActive) {
        await _proxy.disconnect();
        await _settle();
      }
      for (int i = 0; i < candidates.length; i++) {
        if (_cancelled) return _cancelledOutcome(results);
        final String fp = candidates[i];
        onProgress?.call(FixProgress(
            index: i, total: candidates.length, fingerprint: fp, phase: 'connecting'));
        await _settings.setFingerprint(fp);
        final FixResult r = await _measure(i, fp, onProgress);
        results.add(r);
        onProgress?.call(FixProgress(
            index: i,
            total: candidates.length,
            fingerprint: fp,
            phase: 'result',
            result: r));
        await _safeDisconnect();
        await _settle();
      }
      if (_cancelled) return _cancelledOutcome(results);

      // Rank: reachable first, then lowest latency.
      final List<FixResult> ranked = List<FixResult>.of(results)
        ..sort((FixResult a, FixResult b) {
          if (a.reachable != b.reachable) return a.reachable ? -1 : 1;
          return a.latencyMs.compareTo(b.latencyMs);
        });
      final FixResult? winner =
          ranked.isNotEmpty && ranked.first.reachable ? ranked.first : null;

      if (winner == null) {
        await _settings.setFingerprint(original);
        return FixOutcome(success: false, results: ranked);
      }

      // Apply the winner and reconnect onto it so the user ends up protected.
      onProgress?.call(FixProgress(
          index: candidates.length,
          total: candidates.length,
          fingerprint: winner.fingerprint,
          phase: 'applying'));
      await _settings.setFingerprint(winner.fingerprint);
      await _proxy.connect();
      await _waitConnected(const Duration(seconds: 22));
      return FixOutcome(
          success: true, best: winner.fingerprint, results: ranked);
    } catch (_) {
      await _settings.setFingerprint(original);
      await _safeDisconnect();
      return FixOutcome(success: false, results: results);
    }
  }

  FixOutcome _cancelledOutcome(List<FixResult> results) {
    unawaited(_safeDisconnect());
    return FixOutcome(success: false, results: results, cancelled: true);
  }

  Future<FixResult> _measure(
      int i, String fp, void Function(FixProgress)? onProgress) async {
    try {
      await _proxy.connect();
      final bool up = await _waitConnected(const Duration(seconds: 22));
      if (!up || _cancelled) {
        return FixResult(fingerprint: fp, reachable: false, latencyMs: 0);
      }
      onProgress?.call(FixProgress(
          index: i, total: candidates.length, fingerprint: fp, phase: 'probing'));
      return await _reach(fp);
    } catch (_) {
      return FixResult(fingerprint: fp, reachable: false, latencyMs: 0);
    }
  }

  Future<bool> _waitConnected(Duration timeout) async {
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (_cancelled) return false;
      final ProxyConnectionState s = _proxy.state;
      if (s == ProxyConnectionState.connected) return true;
      if ((s == ProxyConnectionState.error ||
              s == ProxyConnectionState.disconnected) &&
          sw.elapsed > const Duration(seconds: 6)) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return _proxy.state == ProxyConnectionState.connected;
  }

  /// A reachable 204 means this fingerprint got past the DPI; time it for the
  /// latency signal. Best of two quick tries so a single hiccup isn't fatal.
  Future<FixResult> _reach(String fp) async {
    int best = -1;
    for (int t = 0; t < 2; t++) {
      if (_cancelled) break;
      final http.Client c = http.Client();
      final Stopwatch sw = Stopwatch()..start();
      try {
        final http.Response r = await c
            .get(Uri.parse('https://www.gstatic.com/generate_204'))
            .timeout(const Duration(seconds: 8));
        if (r.statusCode < 400) {
          final int ms = sw.elapsedMilliseconds;
          if (best < 0 || ms < best) best = ms;
        }
      } catch (_) {/* miss */} finally {
        c.close();
      }
    }
    return FixResult(fingerprint: fp, reachable: best >= 0, latencyMs: best < 0 ? 0 : best);
  }

  Future<void> _safeDisconnect() async {
    try {
      if (_proxy.state.isActive ||
          _proxy.state == ProxyConnectionState.connecting) {
        await _proxy.disconnect();
      }
    } catch (_) {/* ignore */}
  }

  Future<void> _settle() =>
      Future<void>.delayed(const Duration(milliseconds: 1200));
}
