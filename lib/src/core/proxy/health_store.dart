import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'proxy_controller.dart';

/// Saves the ping results, so a test survives the app closing.
///
/// A full sweep takes one to two minutes. It was held only in memory, so
/// anything that tore the app down threw it away: on Android, leaving with the
/// back button rather than home was enough, and the next open would refresh and
/// re-test from nothing. Asking someone to sit through that again because they
/// pressed the wrong exit is not reasonable.
///
/// Stored per profile, because the results belong to a subscription rather than
/// to the app, and cleared when a refresh or a new test replaces them.
class HealthStore {
  HealthStore._();

  static const String _prefix = 'nova.health.';

  /// Results older than this are dropped on load. A latency from last week
  /// describes a server that may not exist any more, and showing it as current
  /// is worse than showing nothing.
  static const Duration maxAge = Duration(hours: 24);

  static SharedPreferences? _prefs;

  static Future<void> save(String profileId, CoreNodeHealth h) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setString(
        '$_prefix$profileId',
        jsonEncode(<String, dynamic>{
          'at': DateTime.now().millisecondsSinceEpoch,
          'delays': h.delayMsByKey,
          'tested': h.testedKeys.toList(),
        }),
      );
    } catch (_) {
      // A failed write costs one re-test, not correctness.
    }
  }

  static Future<CoreNodeHealth?> load(String profileId) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final String? raw = _prefs!.getString('$_prefix$profileId');
      if (raw == null) return null;
      final Map<String, dynamic> j =
          (jsonDecode(raw) as Map).cast<String, dynamic>();
      final int at = (j['at'] as num?)?.toInt() ?? 0;
      final int age = DateTime.now().millisecondsSinceEpoch - at;
      if (age < 0 || age >= maxAge.inMilliseconds) return null;
      final Map<String, int> delays = <String, int>{
        for (final MapEntry<String, dynamic> e
            in (j['delays'] as Map? ?? <String, dynamic>{})
                .cast<String, dynamic>()
                .entries)
          e.key: (e.value as num).toInt(),
      };
      final Set<String> tested = <String>{
        for (final Object? k in (j['tested'] as List? ?? <Object?>[]))
          if (k is String) k,
      };
      if (delays.isEmpty && tested.isEmpty) return null;
      return CoreNodeHealth(delayMsByKey: delays, testedKeys: tested);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear(String profileId) async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.remove('$_prefix$profileId');
    } catch (_) {}
  }
}
