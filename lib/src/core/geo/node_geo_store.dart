import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a node is, as far as Nova knows, keyed by the node's stable key.
///
/// Two sources, one winning: a lookup of the node's address (a guess, and
/// for a CDN-fronted address not even that, just "fronted"), and the exit
/// country observed while actually connected through the node (the truth).
/// Once the truth is known it sticks; a later address lookup never overwrites
/// it. Entries persist across subscription refreshes and app restarts, so a
/// flag that was right yesterday is still right today instead of being
/// re-guessed (or lost) every time the list reloads. The list shows the
/// server's own name for a node in all cases; this only drives the flag.
class NodeGeo {
  const NodeGeo({
    this.countryCode = '',
    this.place = '',
    this.frontedBy,
    this.fromExit = false,
  });

  /// ISO-2 country code, or '' when unknown / fronted.
  final String countryCode;

  /// Short human place ("Frankfurt am Main, DE" or a country name), or ''.
  final String place;

  /// Set when the address belongs to a CDN edge (Cloudflare, ...), in which
  /// case the lookup's country is not where traffic comes out.
  final String? frontedBy;

  /// True when [countryCode] was observed as the real exit while connected.
  final bool fromExit;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cc': countryCode,
        'place': place,
        if (frontedBy != null) 'fronted': frontedBy,
        if (fromExit) 'exit': true,
      };

  factory NodeGeo.fromJson(Map<String, dynamic> j) => NodeGeo(
        countryCode: (j['cc'] as String?) ?? '',
        place: (j['place'] as String?) ?? '',
        frontedBy: j['fronted'] as String?,
        fromExit: j['exit'] == true,
      );
}

class NodeGeoStore extends ChangeNotifier {
  NodeGeoStore._();
  static final NodeGeoStore instance = NodeGeoStore._();

  static const String _kKey = 'nova.nodegeo.v1';
  SharedPreferences? _prefs;
  final Map<String, NodeGeo> _byKey = <String, NodeGeo>{};

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    final String? raw = prefs.getString(_kKey);
    if (raw != null) {
      try {
        final Map<String, dynamic> m =
            (jsonDecode(raw) as Map).cast<String, dynamic>();
        m.forEach((String k, dynamic v) {
          if (v is Map) _byKey[k] = NodeGeo.fromJson(v.cast<String, dynamic>());
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  NodeGeo? operator [](String key) => _byKey[key];

  /// An address-lookup result. Never replaces an exit-observed entry.
  void setGuess(String key, NodeGeo geo) {
    final NodeGeo? cur = _byKey[key];
    if (cur != null && cur.fromExit) return;
    _byKey[key] = geo;
    notifyListeners();
    _persist();
  }

  /// The country seen as the real exit while connected through [key].
  void learnExit(String key, String countryCode, {String? countryName}) {
    if (countryCode.isEmpty) return;
    final NodeGeo? cur = _byKey[key];
    if (cur != null && cur.fromExit && cur.countryCode == countryCode) return;
    _byKey[key] = NodeGeo(
      countryCode: countryCode.toUpperCase(),
      place: countryName ?? cur?.place ?? '',
      fromExit: true,
    );
    notifyListeners();
    _persist();
  }

  /// Drops entries for nodes that no longer belong to any profile. Called by
  /// whoever knows the full current node set; optional housekeeping.
  void retainOnly(Set<String> keys) {
    final int before = _byKey.length;
    _byKey.removeWhere((String k, _) => !keys.contains(k));
    if (_byKey.length != before) {
      notifyListeners();
      _persist();
    }
  }

  void _persist() {
    final SharedPreferences? p = _prefs;
    if (p == null) return;
    p.setString(_kKey, jsonEncode(
        _byKey.map((String k, NodeGeo v) => MapEntry<String, dynamic>(k, v.toJson()))));
  }
}
