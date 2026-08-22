import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/proxy_profile.dart';

/// Owns the user's connection profiles (single links + subscriptions) and
/// persists them. Karing-style clients revolve around this list; the dashboard
/// connects to whichever profile is active.
class ProfilesController extends ChangeNotifier {
  ProfilesController({SharedPreferences? prefs}) : _prefs = prefs {
    _load();
  }

  static const String _kProfilesKey = 'nova.profiles';
  static const String _kActiveKey = 'nova.profiles.active';

  SharedPreferences? _prefs;

  final List<ProxyProfile> _profiles = <ProxyProfile>[];
  List<ProxyProfile> get profiles => List<ProxyProfile>.unmodifiable(_profiles);

  String? _activeId;
  String? get activeId => _activeId;

  ProxyProfile? get active {
    if (_activeId == null) return null;
    for (final p in _profiles) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  /// Profiles added, and ids removed, while [_prefs] was still null. The app
  /// runs for a moment before SharedPreferences resolves; a deep-link import or
  /// a quick user action in that window used to be wiped by [_load] the
  /// instant prefs arrived (and a removal in that window came back). Replayed
  /// on top of the persisted list in [attachPrefs], then persisted.
  final List<ProxyProfile> _addedBeforePrefs = <ProxyProfile>[];
  final Set<String> _removedBeforePrefs = <String>{};
  String? _activeBeforePrefs;

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    _load();
    bool replayed = false;
    if (_removedBeforePrefs.isNotEmpty) {
      _profiles.removeWhere((p) => _removedBeforePrefs.contains(p.id));
      replayed = true;
    }
    for (final ProxyProfile p in _addedBeforePrefs) {
      if (_profiles.any((q) => q.id == p.id)) continue;
      _profiles.add(p);
      replayed = true;
    }
    if (_activeBeforePrefs != null &&
        _profiles.any((p) => p.id == _activeBeforePrefs)) {
      _activeId = _activeBeforePrefs;
      _prefs?.setString(_kActiveKey, _activeId!);
    } else if (_activeId == null && _profiles.isNotEmpty) {
      _activeId = _profiles.first.id;
    }
    _addedBeforePrefs.clear();
    _removedBeforePrefs.clear();
    _activeBeforePrefs = null;
    if (replayed) _persist();
    notifyListeners();
  }

  void _load() {
    final prefs = _prefs;
    if (prefs == null) return;
    final raw = prefs.getString(_kProfilesKey);
    _profiles.clear();
    if (raw != null) {
      try {
        _profiles.addAll(ProxyProfile.decodeList(raw));
      } catch (_) {}
    }
    _pruneBrokenDemos();
    _seedFreeProfile();
    final String? savedActive = prefs.getString(_kActiveKey);
    _activeId =
        (savedActive != null && _profiles.any((p) => p.id == savedActive))
            ? savedActive
            : (_profiles.isNotEmpty ? _profiles.first.id : null);
  }

  /// Earlier builds seeded two placeholder profiles that can never connect: a
  /// "subscription" pointing at the marketing site (which serves HTML, not a
  /// node list) and a `vless://example` stub. Both surfaced on connect as
  /// "Unsupported or invalid profile link", so strip them from any install that
  /// still carries them. New installs start empty and prompt for a real link.
  void _pruneBrokenDemos() {
    final int before = _profiles.length;
    _profiles.removeWhere((ProxyProfile p) =>
        p.id == 'demo-sub' ||
        p.id == 'demo-vless' ||
        p.subscriptionUrl == 'https://novaproxy.online/sub' ||
        p.uri.trim() == 'vless://example');
    if (_profiles.length != before) {
      // Persist the cleanup so it only runs once.
      _prefs?.setString(_kProfilesKey, ProxyProfile.encodeList(_profiles));
    }
  }

  /// Nova's own free servers are always in the list: a fresh install opens on a
  /// Connect button that works, and nobody can end up with nothing.
  ///
  /// Added once per install, to upgrades as well as new installs, since it is a
  /// built-in and not something the user added. What it does NOT do is take
  /// over: an existing user keeps whichever profile they had selected, and the
  /// free list simply appears at the top of theirs.
  @visibleForTesting
  static const String kFreeSeededKey = 'nova.profiles.freeSeeded';

  void _seedFreeProfile() {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    if (_profiles.any((ProxyProfile p) => p.id == kFreeProfileId)) return;
    if (prefs.getBool(kFreeSeededKey) ?? false) return;
    prefs.setBool(kFreeSeededKey, true);
    _profiles.insert(0, buildFreeProfile());
    prefs.setString(_kProfilesKey, ProxyProfile.encodeList(_profiles));
  }

  /// Selects Nova's free servers, adding them first in the one case where they
  /// are somehow missing (a first launch where preferences were not readable
  /// when the list loaded). Returns the profile either way.
  ProxyProfile addFreeProfile() {
    for (final ProxyProfile p in _profiles) {
      if (p.id == kFreeProfileId) {
        setActive(p.id);
        return p;
      }
    }
    final ProxyProfile free = buildFreeProfile();
    add(free);
    setActive(free.id);
    return free;
  }

  bool get hasFreeProfile =>
      _profiles.any((ProxyProfile p) => p.id == kFreeProfileId);

  void setActive(String id) {
    _activeId = id;
    if (_prefs == null) _activeBeforePrefs = id;
    notifyListeners();
    _prefs?.setString(_kActiveKey, id);
  }

  void add(ProxyProfile profile) {
    _profiles.add(profile);
    _activeId ??= profile.id;
    if (_prefs == null) {
      _addedBeforePrefs.add(profile);
      _removedBeforePrefs.remove(profile.id);
    }
    notifyListeners();
    _persist();
  }

  void remove(String id) {
    // Nova's own free servers are not the user's to delete. They are what makes
    // "install it and press Connect" true, including for the person who has
    // just deleted everything else, so the store refuses here rather than
    // trusting every screen to hide the button.
    if (id == kFreeProfileId) return;
    _profiles.removeWhere((p) => p.id == id);
    if (_prefs == null) {
      _removedBeforePrefs.add(id);
      _addedBeforePrefs.removeWhere((p) => p.id == id);
    }
    if (_activeId == id) {
      _activeId = _profiles.isNotEmpty ? _profiles.first.id : null;
      if (_activeId != null) _prefs?.setString(_kActiveKey, _activeId!);
    }
    notifyListeners();
    _persist();
  }

  void update(ProxyProfile profile) {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx < 0) return;
    _profiles[idx] = profile;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    await _prefs?.setString(_kProfilesKey, ProxyProfile.encodeList(_profiles));
  }
}
