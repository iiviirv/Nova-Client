import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/nova_log.dart';

/// One Cloudflare address that was reachable from THIS device, and when.
@immutable
class CleanIp {
  const CleanIp({
    required this.ip,
    required this.port,
    required this.latencyMs,
    required this.foundAtMs,
  });

  final String ip;
  final int port;
  final int latencyMs;
  final int foundAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ip': ip,
        'port': port,
        'latencyMs': latencyMs,
        'foundAtMs': foundAtMs,
      };

  static CleanIp? fromJson(Map<String, dynamic> j) {
    final String? ip = j['ip'] as String?;
    if (ip == null || ip.isEmpty) return null;
    return CleanIp(
      ip: ip,
      port: (j['port'] as num?)?.toInt() ?? 443,
      latencyMs: (j['latencyMs'] as num?)?.toInt() ?? 0,
      foundAtMs: (j['foundAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The clean Cloudflare address this device connects through.
///
/// A subscription hands out servers by domain, and in Iran those domains are
/// filtered quickly while the addresses behind them keep working. Dialling a
/// Cloudflare IP directly and sending the domain only as the TLS name is what
/// keeps such a config usable, and it is also what turns on Nova's SNI-block
/// bypass, which only applies to a node whose address is already an IP.
///
/// Which addresses are clean is not a global fact. It depends on the network
/// the phone is on right now, so one IP shipped to everybody is wrong for most
/// of them and burns out for the rest. Each device finds and keeps its own,
/// using the scanner Nova already carries.
class CleanIpStore extends ChangeNotifier {
  CleanIpStore._();
  static final CleanIpStore instance = CleanIpStore._();

  static const String _kKey = 'nova.cleanip.best';
  static const String _kPoolKey = 'nova.cleanip.pool';
  static const String _kBoostKey = 'nova.cleanip.boost';

  /// How many of a scan's best addresses are kept to spread across the free
  /// list. Five is enough that losing one does not empty the list, and few
  /// enough that they are all genuinely fast.
  static const int kPoolSize = 5;

  /// How long a find is trusted. A clean address usually stays clean for days,
  /// but the network the phone is on can change under it, so it is re-checked
  /// rather than kept forever.
  static const Duration maxAge = Duration(hours: 12);

  SharedPreferences? _prefs;
  CleanIp? _best;
  CleanIp? get best => _best;

  bool _searching = false;
  bool get searching => _searching;

  List<CleanIp> _pool = const <CleanIp>[];

  /// The best addresses the last scan found, freshest first. Empty until a scan
  /// has run.
  List<CleanIp> get pool => List<CleanIp>.unmodifiable(_pool);

  /// Only the ones still young enough to dial.
  List<CleanIp> get freshPool {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return <CleanIp>[
      for (final CleanIp c in _pool)
        if (now - c.foundAtMs >= 0 && now - c.foundAtMs < maxAge.inMilliseconds)
          c,
    ];
  }

  bool _boost = false;

  /// Whether a free-list refresh should re-address its servers through
  /// [freshPool]. Off by default: it changes what every server in the list
  /// dials, which is not something to do to someone without asking.
  bool get boostFreeList => _boost;

  Future<void> setBoostFreeList(bool on) async {
    if (_boost == on) return;
    _boost = on;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_kBoostKey, on);
  }

  /// Keeps the best [kPoolSize] of a scan's results.
  Future<void> recordPool(List<CleanIp> ips) async {
    final List<CleanIp> sorted = <CleanIp>[...ips]
      ..sort((CleanIp a, CleanIp b) => a.latencyMs.compareTo(b.latencyMs));
    _pool = sorted.take(kPoolSize).toList();
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kPoolKey,
        jsonEncode(<Map<String, dynamic>>[
          for (final CleanIp c in _pool) c.toJson(),
        ]));
    NovaLog.instance.write(
        'Kept ${_pool.length} scanned addresses for the free list');
  }

  /// A stored address that is still young enough to use.
  CleanIp? get fresh {
    final CleanIp? b = _best;
    if (b == null) return null;
    final int age = DateTime.now().millisecondsSinceEpoch - b.foundAtMs;
    return age >= 0 && age < maxAge.inMilliseconds ? b : null;
  }

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final String? raw = _prefs!.getString(_kKey);
    if (raw == null) return;
    try {
      _best = CleanIp.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
      notifyListeners();
    } catch (_) {}
    _boost = _prefs!.getBool(_kBoostKey) ?? false;
    final String? poolRaw = _prefs!.getString(_kPoolKey);
    if (poolRaw != null) {
      try {
        final List<CleanIp> loaded = <CleanIp>[];
        for (final Object? e in jsonDecode(poolRaw) as List<dynamic>) {
          if (e is! Map) continue;
          final CleanIp? c = CleanIp.fromJson(e.cast<String, dynamic>());
          if (c != null) loaded.add(c);
        }
        _pool = loaded;
      } catch (_) {
        _pool = const <CleanIp>[];
      }
    }
    notifyListeners();
  }

  Future<void> record(CleanIp ip) async {
    _best = ip;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kKey, jsonEncode(ip.toJson()));
    NovaLog.instance.write(
        'Clean address for this network: ${ip.ip}:${ip.port} (${ip.latencyMs}ms)');
  }

  Future<void> clear() async {
    _best = null;
    notifyListeners();
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.remove(_kKey);
  }

  /// Sets the address without persisting it. Used when saving failed, so a
  /// good find is still usable for this session, and by tests.
  void hold(CleanIp? ip) {
    _best = ip;
    notifyListeners();
  }

  /// Guards against two searches at once; the caller owns the actual scanning.
  bool beginSearch() {
    if (_searching) return false;
    _searching = true;
    notifyListeners();
    return true;
  }

  void endSearch() {
    _searching = false;
    notifyListeners();
  }

}
