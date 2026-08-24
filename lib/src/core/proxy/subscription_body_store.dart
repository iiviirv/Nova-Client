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

/// A [SubInfoStore] backed by SharedPreferences, so a subscription's plan
/// usage and expiry survive a restart.
///
/// Same hashed key scheme as the body store above: the subscription URL carries
/// query auth, so it never sits in prefs in the clear. One small JSON object per
/// subscription.
class PrefsSubInfoStore implements SubInfoStore {
  PrefsSubInfoStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _prefix = 'nova.subinfo.';

  String _keyFor(String url) => '$_prefix${sha256.convert(utf8.encode(url))}';

  @override
  Map<String, SubInfo> loadAll() {
    final Map<String, SubInfo> out = <String, SubInfo>{};
    for (final String key in _prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final String? raw = _prefs.getString(key);
      if (raw == null) continue;
      try {
        final Map<String, dynamic> j =
            (jsonDecode(raw) as Map).cast<String, dynamic>();
        final String? url = j['url'] as String?;
        if (url == null) continue;
        final int? exp = (j['expire'] as num?)?.toInt();
        out[url] = SubInfo(
          upload: (j['upload'] as num?)?.toInt() ?? 0,
          download: (j['download'] as num?)?.toInt() ?? 0,
          total: (j['total'] as num?)?.toInt() ?? 0,
          expire: exp == null || exp <= 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(exp),
        );
      } catch (_) {
        // A prefs entry we cannot read is not worth failing startup over.
      }
    }
    return out;
  }

  @override
  Future<void> save(String url, SubInfo info) async {
    await _prefs.setString(
      _keyFor(url),
      jsonEncode(<String, dynamic>{
        'url': url,
        'upload': info.upload,
        'download': info.download,
        'total': info.total,
        'expire': info.expire?.millisecondsSinceEpoch,
      }),
    );
  }
}
