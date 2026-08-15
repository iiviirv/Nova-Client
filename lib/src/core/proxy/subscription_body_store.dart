import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription.dart';

/// A [SubscriptionBodyStore] backed by SharedPreferences, so the last good raw
/// body of each subscription survives an app restart.
///
/// The point is resilience for the workers.dev-blocked case: when the panel URL
/// can't be refreshed, the saved body is what lets the server list and the
/// tunnel keep using the servers the user already has (those connect to clean
/// IPs, not the blocked domain), instead of failing with an empty list.
///
/// Keys are hashed so an arbitrarily long subscription URL (with query auth)
/// stays a fixed, prefs-safe key, and the raw URL never sits in prefs in the
/// clear. Only the most recent body per URL is kept.
class PrefsSubscriptionBodyStore implements SubscriptionBodyStore {
  PrefsSubscriptionBodyStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _prefix = 'nova.subbody.';

  /// A subscription body can be tens of KB for a large pool; cap what we persist
  /// so a pathological sub can't bloat prefs. This is plenty for hundreds of
  /// nodes and a body larger than this would not have parsed cleanly anyway.
  static const int _maxBytes = 512 * 1024;

  String _keyFor(String url) =>
      '$_prefix${sha256.convert(utf8.encode(url))}';

  @override
  Future<String?> load(String url) async {
    return _prefs.getString(_keyFor(url));
  }

  @override
  Future<void> save(String url, String body) async {
    if (body.isEmpty || body.length > _maxBytes) return;
    await _prefs.setString(_keyFor(url), body);
  }
}
