import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  bool get isScanning => _scanner?.isScanning ?? false;

  NovaCoreConfig? _coreConfig;
  NovaCoreConfig? get coreConfig => _coreConfig;

  String _exitColo = '';
  String get exitColo => _exitColo;

  /// Binds the active subscription's core config (and the exit colo used for
  /// flagging) so scans emit real, importable nodes named like the worker.
  /// Pass `null` to unbind and fall back to bare `ip:port#name` results.
  void applyCoreConfig(NovaCoreConfig? config, {String colo = ''}) {
    _coreConfig = config;
    _exitColo = colo;
    notifyListeners();
  }

  bool _binding = false;
  bool get isBindingSubscription => _binding;

  String? _bindError;
  String? get bindError => _bindError;

  /// Fetches [subUrl], derives the core config and exit colo, and binds them.
  /// Best-effort: progress shows via [isBindingSubscription] and failures via
  /// [bindError]. [fetch] overrides the transport (used in tests).
  Future<void> bindSubscription(
    String subUrl, {
    SubscriptionFetcher? fetch,
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
      applyCoreConfig(cfg, colo: colo);
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
      _results.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
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

    await _teardownScanner();
    notifyListeners();
  }

  void stopScan() => _scanner?.stop();

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
