import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../core/proxy/singbox/nova_naming.dart';
import '../../core/proxy/singbox/share_link_builder.dart';
import '../../core/proxy/subscription.dart';
import 'models.dart';
import 'sources.dart';

/// Nova Radar's two-phase Cloudflare clean-IP scanner, ported from the Go
/// implementation (`scanner.go`):
///
///   * **Phase 1 — quick scan:** a TCP connect to every `ip:port`, collecting
///     reachable candidates with their connect latency.
///   * **Phase 2 — deep test:** real protocol verification — a TLS handshake
///     (with the Nova Worker SNI) on TLS ports, or a TCP read probe on HTTP
///     ports — run 3× per candidate, keeping those that pass ≥2 times.
///
/// Results are sorted fastest-first. Progress is streamed to the UI, throttled
/// so the event rate stays UI-friendly even with hundreds of concurrent probes.
class NovaScanner {
  NovaScanner({
    this.sampleSize = 512,
    this.quickConcurrency = 400,
    this.deepConcurrency = 100,
    this.quickTimeout = const Duration(seconds: 2),
    this.deepTimeout = const Duration(seconds: 3),
    this.coreConfig,
    this.colo = '',
    this.suffix = kRadarSuffix,
  });

  final int sampleSize;
  final int quickConcurrency;
  final int deepConcurrency;
  final Duration quickTimeout;
  final Duration deepTimeout;

  /// The active subscription's core config. When present, results are real
  /// `vless://` nodes stamped into its template; when null, the scanner falls
  /// back to a bare `ip:port#name`.
  final NovaCoreConfig? coreConfig;

  /// The exit datacenter colo used to flag node names, matching the core.
  final String colo;

  /// Marker appended to Radar-found node names.
  final String suffix;

  final StreamController<ScanResult> _resultsCtrl =
      StreamController<ScanResult>.broadcast();
  final StreamController<ScanStats> _statsCtrl =
      StreamController<ScanStats>.broadcast();

  /// Emits each verified clean IP as it is confirmed.
  Stream<ScanResult> get onResult => _resultsCtrl.stream;

  /// Emits throttled scan statistics.
  Stream<ScanStats> get onStats => _statsCtrl.stream;

  final Random _rng = Random.secure();

  bool _scanning = false;
  bool _stop = false;
  bool get isScanning => _scanning;

  int _totalScanned = 0;
  int _totalToScan = 0;
  int _alive = 0;
  int _dead = 0;
  String _currentIp = '';
  int _currentPort = 0;
  bool _secondPass = false;
  DateTime? _startTime;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Runs a full scan and returns the sorted results. Safe to await; progress
  /// arrives on [onStats] / [onResult] while it runs.
  Future<List<ScanResult>> start({
    required List<IpSource> sources,
    required List<int> ports,
  }) async {
    if (_scanning) return const <ScanResult>[];
    if (ports.isEmpty) return const <ScanResult>[];

    _scanning = true;
    _stop = false;
    _totalScanned = 0;
    _alive = 0;
    _dead = 0;
    _secondPass = false;
    _currentIp = '';
    _currentPort = 0;
    _startTime = DateTime.now();
    _emitStats(force: true);

    try {
      final CandidatePool pool = await fetchIpsFromSources(sources);
      final List<String> ips = generateRandomIps(pool.cidrs, sampleSize)
        ..addAll(pool.directIps);
      if (ips.isEmpty || _stop) return const <ScanResult>[];
      ips.shuffle(_rng);

      _totalToScan = ips.length * ports.length * 2;
      _emitStats(force: true);

      final List<ScanResult> candidates = await _quickScan(ips, ports);
      if (_stop || candidates.isEmpty) {
        return _finish(<ScanResult>[]);
      }

      _secondPass = true;
      _emitStats(force: true);
      final List<ScanResult> verified = await _deepTest(candidates);
      return _finish(verified);
    } finally {
      _scanning = false;
      _secondPass = false;
      _emitStats(force: true);
    }
  }

  /// Requests the in-flight scan to stop at the next checkpoint.
  void stop() => _stop = true;

  Future<void> dispose() async {
    _stop = true;
    await _resultsCtrl.close();
    await _statsCtrl.close();
  }

  List<ScanResult> _finish(List<ScanResult> results) {
    results.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    _alive = results.length;
    _emitStats(force: true);
    return results;
  }

  // -------------------------------------------------------------------------
  // Phase 1 — quick TCP scan
  // -------------------------------------------------------------------------
  Future<List<ScanResult>> _quickScan(List<String> ips, List<int> ports) async {
    final List<ScanResult> candidates = <ScanResult>[];
    final List<_Probe> tasks = <_Probe>[
      for (final String ip in ips)
        for (final int port in ports) _Probe(ip, port),
    ];

    await _forEachBounded(tasks, quickConcurrency, (probe) async {
      _currentIp = probe.ip;
      _currentPort = probe.port;
      _totalScanned++;
      final int? latency = await _tcpConnect(probe.ip, probe.port, quickTimeout);
      if (latency != null) {
        candidates.add(ScanResult(
          ip: probe.ip,
          port: probe.port,
          link: _novaLink(probe.ip, probe.port),
          latencyMs: latency,
        ));
        _alive++;
      } else {
        _dead++;
      }
      _emitStats();
    });
    return candidates;
  }

  // -------------------------------------------------------------------------
  // Phase 2 — deep protocol verification
  // -------------------------------------------------------------------------
  Future<List<ScanResult>> _deepTest(List<ScanResult> candidates) async {
    final List<_Verified> verified =
        candidates.map((c) => _Verified(c)).toList();

    // 3 attempts per candidate, run through the bounded pool.
    final List<_Attempt> attempts = <_Attempt>[
      for (int i = 0; i < verified.length; i++)
        for (int a = 0; a < 3; a++) _Attempt(i),
    ];

    // Reset alive — only deep-verified IPs count from here.
    _alive = 0;

    await _forEachBounded(attempts, deepConcurrency, (attempt) async {
      final _Verified v = verified[attempt.index];
      _currentIp = v.result.ip;
      _currentPort = v.result.port;
      _totalScanned++;
      final Stopwatch sw = Stopwatch()..start();
      final bool ok = await _deepConnect(v.result.ip, v.result.port);
      final int latency = sw.elapsedMilliseconds;
      if (ok) {
        v.success++;
        if (v.latency == 0 || latency < v.latency) v.latency = latency;
      } else {
        _dead++;
      }
      _emitStats();
    });

    final List<ScanResult> out = <ScanResult>[];
    for (final _Verified v in verified) {
      if (v.success >= 2) {
        final ScanResult r = ScanResult(
          ip: v.result.ip,
          port: v.result.port,
          link: _novaLink(v.result.ip, v.result.port),
          latencyMs: v.latency,
        );
        out.add(r);
        _resultsCtrl.add(r);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Probes
  // -------------------------------------------------------------------------
  Future<int?> _tcpConnect(String ip, int port, Duration timeout) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      final Socket socket = await Socket.connect(ip, port, timeout: timeout);
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _deepConnect(String ip, int port) async {
    try {
      if (kTlsPorts.contains(port)) {
        final Socket raw = await Socket.connect(ip, port, timeout: deepTimeout);
        try {
          // Present the active worker host as SNI so the handshake validates
          // against the endpoint traffic actually uses, not a stale constant.
          final SecureSocket secure = await SecureSocket.secure(
            raw,
            host: coreConfig?.sni ?? kVlessSni,
            onBadCertificate: (_) => true,
          ).timeout(deepTimeout);
          secure.destroy();
          return true;
        } catch (_) {
          raw.destroy();
          return false;
        }
      }
      // HTTP ports: strict TCP read probe (a byte must arrive before deadline).
      final Socket socket = await Socket.connect(ip, port, timeout: deepTimeout);
      final Completer<bool> completer = Completer<bool>();
      final Timer timer = Timer(deepTimeout, () {
        if (!completer.isCompleted) completer.complete(false);
      });
      late final StreamSubscription<List<int>> sub;
      sub = socket.listen(
        (data) {
          if (data.isNotEmpty && !completer.isCompleted) {
            completer.complete(true);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );
      final bool ok = await completer.future;
      timer.cancel();
      await sub.cancel();
      socket.destroy();
      return ok;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Concurrency + stats
  // -------------------------------------------------------------------------

  /// Runs [body] over [items] with at most [concurrency] in flight. Workers
  /// pull from a shared iterator; Dart's single-threaded event loop makes the
  /// shared cursor safe across the cooperative `await` points.
  Future<void> _forEachBounded<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T) body,
  ) async {
    final Iterator<T> it = items.iterator;
    final int workers = min(concurrency, items.length);
    await Future.wait(<Future<void>>[
      for (int w = 0; w < workers; w++)
        () async {
          while (!_stop && it.moveNext()) {
            await body(it.current);
          }
        }(),
    ]);
  }

  ScanStats _stats() {
    int elapsed = 0;
    int remaining = 0;
    final DateTime? start = _startTime;
    if (start != null) {
      elapsed = DateTime.now().difference(start).inSeconds;
    }
    if (_totalScanned > 0 && elapsed > 5) {
      final int rate = _totalScanned ~/ elapsed;
      if (rate > 0) remaining = (_totalToScan - _totalScanned) ~/ rate;
    }
    return ScanStats(
      totalScanned: _totalScanned,
      totalToScan: _totalToScan,
      aliveCount: _alive,
      deadCount: _dead,
      scanning: _scanning,
      currentIp: _currentIp,
      currentPort: _currentPort,
      elapsedSec: elapsed,
      remainingSec: remaining < 0 ? 0 : remaining,
      secondPass: _secondPass,
    );
  }

  void _emitStats({bool force = false}) {
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastEmit).inMilliseconds < 100) return;
    _lastEmit = now;
    if (!_statsCtrl.isClosed) _statsCtrl.add(_stats());
  }

  /// Builds the result entry for a clean [ip]:[port]. With an active core
  /// config this is a full, importable `vless://` node stamped into the
  /// subscription template and named `{flag} Nova-{id}{suffix}` exactly like
  /// the worker; otherwise it falls back to a bare `ip:port#name`.
  String _novaLink(String ip, int port) {
    final String name = novaNodeName(colo: colo, suffix: suffix, rng: _rng);
    final template = coreConfig?.template;
    if (template != null) {
      return stampCleanIp(template: template, ip: ip, port: port, name: name);
    }
    return '$ip:$port#$name';
  }
}

class _Probe {
  _Probe(this.ip, this.port);
  final String ip;
  final int port;
}

class _Verified {
  _Verified(this.result);
  final ScanResult result;
  int success = 0;
  int latency = 0;
}

class _Attempt {
  _Attempt(this.index);
  final int index;
}
