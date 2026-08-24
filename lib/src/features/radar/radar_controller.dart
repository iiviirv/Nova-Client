import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/cleanip/clean_ip_store.dart';
import '../../core/proxy/subscription.dart';
import 'models.dart';
import 'scanner.dart';
import 'sources.dart';

/// Drives the Radar screen: owns the source list, the selected ports, the live
/// scan stats and the result set, and persists the user's source/port choices.
class RadarController extends ChangeNotifier {
  RadarController({SharedPreferences? prefs}) : _prefs = prefs {
    _sources = defaultSources();
    _selectedPorts = <int>{443, 2053, 8443};
    _load();
  }

  static const String _kSourcesKey = 'nova.radar.sources';
  static const String _kPortsKey = 'nova.radar.ports';

  SharedPreferences? _prefs;
  NovaScanner? _scanner;
  StreamSubscription<ScanStats>? _statsSub;
  StreamSubscription<ScanResult>? _resultSub;

  late List<IpSource> _sources;
  List<IpSource> get sources => List<IpSource>.unmodifiable(_sources);

  late Set<int> _selectedPorts;
  Set<int> get selectedPorts => Set<int>.unmodifiable(_selectedPorts);

  ScanStats _stats = ScanStats.idle;
  ScanStats get stats => _stats;

  final List<ScanResult> _results = <ScanResult>[];
  List<ScanResult> get results => List<ScanResult>.unmodifiable(_results);

  // Real-delay results keyed by "ip:port". Held here (not on the immutable
  // ScanResult) so re-testing just updates the map without rebuilding results.
  final Map<String, int?> _realDelays = <String, int?>{};
  bool _testingDelays = false;
  bool get isTestingDelays => _testingDelays;

  /// The measured real delay (ms) for a result, or null if it hasn't been
  /// tested yet or the last test failed. Use [hasRealDelay] to tell them apart.
  int? realDelayFor(String hostPort) => _realDelays[hostPort];
  bool hasRealDelay(String hostPort) => _realDelays.containsKey(hostPort);

  bool get isScanning => _scanner?.isScanning ?? false;

  NovaCoreConfig? _coreConfig;
  NovaCoreConfig? get coreConfig => _coreConfig;

  String _exitColo = '';
  String get exitColo => _exitColo;

  /// Binds the active subscription's core config (and the exit colo used for
  /// flagging) so scans emit real, importable nodes named like the worker.
  /// Pass `null` to unbind and fall back to bare `ip:port#name` results.
  ///
  /// [ownDomain] marks a config that came from a subscription the user pays
  /// for, which changes what the scan is allowed to dial. See [scanHost].
  void applyCoreConfig(NovaCoreConfig? config,
      {String colo = '', bool ownDomain = false}) {
    _coreConfig = config;
    _exitColo = colo;
    _configIsOwnDomain = ownDomain;
    notifyListeners();
  }

  bool _configIsOwnDomain = false;

  /// The SNI a scan dials, which is deliberately NOT the user's own domain.
  ///
  /// A scan is hundreds of TLS handshakes to one name in a few seconds, and
  /// Iranian DPI reacts to exactly that: the domain being scanned starts getting
  /// disrupted within hours. When that domain is the panel someone pays for,
  /// Radar burns the very thing it was run to improve. So the handshakes go to a
  /// Cloudflare name that is ours to spend, and the user's config is still used
  /// as the template for the nodes a scan emits, because what the scan is
  /// looking for is a reachable edge IP and reachability does not depend on
  /// which name rode the handshake.
  String get scanHost {
    if (_configIsOwnDomain) return kVlessSni;
    final String? sni = _coreConfig?.sni;
    return (sni == null || sni.isEmpty) ? kVlessSni : sni;
  }

  bool _binding = false;
  bool get isBindingSubscription => _binding;

  String? _bindError;
  String? get bindError => _bindError;

  /// Fetches [subUrl], derives the core config and exit colo, and binds them.
  /// Best-effort: progress shows via [isBindingSubscription] and failures via
  /// [bindError]. [fetch] overrides the transport (used in tests).
  /// [ownDomain] says this subscription is one the user pays for, so its
  /// domain must not be the one a scan dials. See [scanHost].
  Future<void> bindSubscription(
    String subUrl, {
    SubscriptionFetcher? fetch,
    bool ownDomain = true,
  }) async {
    if (_binding || subUrl.isEmpty) return;
    _binding = true;
    _bindError = null;
    notifyListeners();
    try {
      final NovaCoreConfig? cfg = await fetchCoreConfig(subUrl, fetch: fetch);
      if (cfg == null) {
        _bindError = 'empty';
        _binding = false;
        notifyListeners();
        return;
      }
      final String colo = await fetchExitColo(fetch: fetch);
      _binding = false;
      applyCoreConfig(cfg, colo: colo, ownDomain: ownDomain);
    } catch (e) {
      _bindError = e.toString();
      _binding = false;
      notifyListeners();
    }
  }

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    _load();
    notifyListeners();
  }

  void _load() {
    final prefs = _prefs;
    if (prefs == null) return;
    final rawSources = prefs.getString(_kSourcesKey);
    if (rawSources != null) {
      try {
        final List<dynamic> data = jsonDecode(rawSources) as List<dynamic>;
        final saved = data
            .map((e) => IpSource.fromJson(e as Map<String, dynamic>))
            .toList();
        // Merge saved "enabled" flags onto the canonical default list so new
        // built-in sources still appear after an app update.
        final byId = {for (final s in saved) s.id: s};
        _sources = defaultSources()
            .map((s) => s.copyWith(enabled: byId[s.id]?.enabled ?? s.enabled))
            .toList();
      } catch (_) {
        _sources = defaultSources();
      }
    }
    final rawPorts = prefs.getStringList(_kPortsKey);
    if (rawPorts != null && rawPorts.isNotEmpty) {
      _selectedPorts = rawPorts.map(int.parse).toSet();
    }
  }

  void toggleSource(String id, bool enabled) {
    final idx = _sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    _sources[idx].enabled = enabled;
    notifyListeners();
    _persistSources();
  }

  void togglePort(int port) {
    if (_selectedPorts.contains(port)) {
      if (_selectedPorts.length == 1) return; // keep at least one port
      _selectedPorts.remove(port);
    } else {
      _selectedPorts.add(port);
    }
    notifyListeners();
    _persistPorts();
  }

  void resetSources() {
    _sources = defaultSources();
    notifyListeners();
    _persistSources();
  }

  Future<void> _persistSources() async {
    await _prefs?.setString(
      _kSourcesKey,
      jsonEncode(_sources.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> _persistPorts() async {
    await _prefs?.setStringList(
      _kPortsKey,
      _selectedPorts.map((p) => p.toString()).toList(),
    );
  }

  Future<void> startScan() async {
    if (isScanning) return;
    _results.clear();
    _realDelays.clear();
    _stats = const ScanStats(scanning: true);
    notifyListeners();

    final scanner = NovaScanner(coreConfig: _coreConfig, colo: _exitColo);
    _scanner = scanner;
    _statsSub = scanner.onStats.listen((s) {
      _stats = s;
      notifyListeners();
    });
    _resultSub = scanner.onResult.listen((r) {
      _results.add(r);
      _results.sort((a, b) => a.score.compareTo(b.score));
      notifyListeners();
    });

    final ports = kAllPorts.where(_selectedPorts.contains).toList();
    final List<ScanResult> finalResults =
        await scanner.start(sources: _sources, ports: ports);

    // The returned list is the authoritative, fully-sorted result set; adopt it
    // so the UI is correct regardless of stream-delivery timing.
    _results
      ..clear()
      ..addAll(finalResults);

    // Set the final Alive count from the authoritative results too: the scanner's
    // last stats emit arrives over a stream that teardown can cancel before it's
    // delivered, which left Alive reading 0 after a scan that clearly found IPs.
    _stats = _stats.copyWith(
      aliveCount: finalResults.length,
      scanning: false,
      secondPass: false,
    );

    // Keep the best few for the free list. Doing it here rather than on the
    // toggle means the addresses are already there the moment someone turns it
    // on, instead of the setting doing nothing until the next scan.
    await _keepBestForFreeList(finalResults);

    await _teardownScanner();
    notifyListeners();
  }

  /// Stores the best [CleanIpStore.kPoolSize] addresses of a scan.
  Future<void> _keepBestForFreeList(List<ScanResult> results) async {
    if (results.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    // Ranked by the scanner's own score, which already folds in jitter and
    // loss rather than latency alone, so the kept few are the ones that were
    // steady and not merely quick once.
    final List<ScanResult> best = <ScanResult>[...results]
      ..sort((ScanResult a, ScanResult b) => a.score.compareTo(b.score));
    await CleanIpStore.instance.recordPool(<CleanIp>[
      for (final ScanResult r in best.take(CleanIpStore.kPoolSize))
        CleanIp(
          ip: r.ip,
          port: r.port,
          latencyMs: r.latencyMs,
          foundAtMs: now,
        ),
    ]);
  }

  void stopScan() => _scanner?.stop();

  /// Runs a real-delay test (full HTTP round-trip through each clean IP) over
  /// the current results, a few at a time so it stays light, and re-sorts the
  /// list by the honest measured delay once done. Untested/failed entries keep
  /// their connect latency for ordering. Safe to call again to re-measure.
  Future<void> testRealDelays() async {
    if (_testingDelays || isScanning || _results.isEmpty) return;
    _testingDelays = true;
    notifyListeners();

    final String host = scanHost;
    final List<ScanResult> snapshot = List<ScanResult>.of(_results);
    final Iterator<ScanResult> it = snapshot.iterator;
    const int concurrency = 8;

    Future<void> worker() async {
      while (it.moveNext()) {
        final ScanResult r = it.current;
        final int? ms = await measureRealDelay(r.ip, r.port, host: host);
        _realDelays[r.hostPort] = ms;
        notifyListeners();
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);

    // Re-order fastest-first by real delay; anything untested/failed sinks to
    // the bottom keeping its relative connect-latency order.
    _results.sort((ScanResult a, ScanResult b) {
      final int da = _realDelays[a.hostPort] ?? 1 << 30;
      final int db = _realDelays[b.hostPort] ?? 1 << 30;
      if (da != db) return da.compareTo(db);
      return a.score.compareTo(b.score);
    });

    _testingDelays = false;
    notifyListeners();
  }

  Future<void> _teardownScanner() async {
    await _statsSub?.cancel();
    await _resultSub?.cancel();
    _statsSub = null;
    _resultSub = null;
    await _scanner?.dispose();
    _scanner = null;
  }

  /// All result links joined by newline — for "copy all" / export.
  String exportText() => _results.map((r) => r.link).join('\n');

  @override
  void dispose() {
    _teardownScanner();
    super.dispose();
  }
}
