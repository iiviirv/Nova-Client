import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/proxy_profile.dart';

/// When each subscription's server list was last fetched and swept.
///
/// Opening a server list used to re-download the subscription and run a sweep
/// every single time, so moving between tabs re-tested a few hundred servers
/// and, on the free list, could not be avoided. The list is not that
/// perishable: a subscription changes rarely, and a server that answered a
/// minute ago will almost certainly answer now.
///
/// So the work is done when it is worth doing, and otherwise the saved list and
/// its recorded numbers are shown as they are. The refresh button is always
/// there for anyone who wants it now, and it ignores this entirely.
///
/// Persisted rather than held in memory: the old 15-minute window lived in a
/// static map, so every cold start swept again regardless of how recently the
/// last one ran.
class ListFreshness {
  ListFreshness._();

  /// The window for a subscription the user added themselves. Their provider's
  /// servers are stable, so re-sweeping them more often is wasted work.
  static const Duration maxAge = Duration(hours: 12);

  /// The window for Nova's own free list, which is a different kind of list:
  /// it is rebuilt upstream every hour and loses roughly 40% of its servers in
  /// four, so 12 hours hands people a list that is mostly gone by the time they
  /// look at it. Measured 2026-08-28: of 87 servers published at 11:39 UTC, 50
  /// still carried traffic five hours later.
  static const Duration freeMaxAge = Duration(hours: 1);

  /// How old [profileId]'s list may get before it is re-fetched.
  static Duration maxAgeFor(String profileId) =>
      profileId == kFreeProfileId ? freeMaxAge : maxAge;
  static const String _prefix = 'nova.listfresh.';

  static SharedPreferences? _prefs;
  static final Map<String, int> _memory = <String, int>{};

  static Future<void> load() async {
    // Re-read rather than reuse: load means "take the state from disk", so
    // calling it twice must agree with disk both times.
    _prefs = await SharedPreferences.getInstance();
    _memory.clear();
    for (final String k in _prefs!.getKeys()) {
      if (!k.startsWith(_prefix)) continue;
      final int? v = _prefs!.getInt(k);
      if (v != null) _memory[k.substring(_prefix.length)] = v;
    }
  }

  /// Whether [profileId] is due a re-fetch and a sweep. Unknown means yes: a
  /// list that has never been synced on this device has nothing to show.
  static bool isStale(String profileId) {
    final int? at = _memory[profileId];
    if (at == null) return true;
    final int age = DateTime.now().millisecondsSinceEpoch - at;
    return age < 0 || age >= maxAgeFor(profileId).inMilliseconds;
  }

  static DateTime? lastSync(String profileId) {
    final int? at = _memory[profileId];
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Records that [profileId] has just been fetched and swept.
  static Future<void> markSynced(String profileId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    _memory[profileId] = now;
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.setInt('$_prefix$profileId', now);
    } catch (_) {
      // The in-memory value still holds for this session; a failed write only
      // costs one extra sweep after a restart.
    }
  }

  /// Forgets [profileId], so the next open re-fetches and re-sweeps. What the
  /// manual refresh button leaves behind.
  static Future<void> invalidate(String profileId) async {
    _memory.remove(profileId);
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs!.remove('$_prefix$profileId');
    } catch (_) {}
  }
}
