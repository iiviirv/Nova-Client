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

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    _load();
    notifyListeners();
  }

  void _load() {
    final prefs = _prefs;
    if (prefs == null) {
      if (_profiles.isEmpty) _seedDemo();
      return;
    }
    final raw = prefs.getString(_kProfilesKey);
    _profiles.clear();
    if (raw != null) {
      try {
        _profiles.addAll(ProxyProfile.decodeList(raw));
      } catch (_) {}
    }
    if (_profiles.isEmpty) _seedDemo();
    _activeId = prefs.getString(_kActiveKey) ?? _profiles.first.id;
  }

  /// A couple of placeholder profiles so the dashboard is meaningful on first
  /// run, before the user imports a real Nova subscription.
  void _seedDemo() {
    _profiles.addAll(<ProxyProfile>[
      ProxyProfile(
        id: 'demo-sub',
        name: 'Nova Proxy — Subscription',
        kind: ProxyKind.subscription,
        uri: '',
        subscriptionUrl: 'https://novaproxy.online/sub',
        nodeCount: 6,
        lastLatencyMs: 84,
        updatedAt: DateTime.now(),
      ),
      ProxyProfile(
        id: 'demo-vless',
        name: 'Nova VLESS — Direct',
        kind: ProxyKind.vless,
        uri: 'vless://example',
        lastLatencyMs: 132,
        updatedAt: DateTime.now(),
      ),
    ]);
    _activeId ??= _profiles.first.id;
  }

  void setActive(String id) {
    _activeId = id;
    notifyListeners();
    _prefs?.setString(_kActiveKey, id);
  }

  void add(ProxyProfile profile) {
    _profiles.add(profile);
    _activeId ??= profile.id;
    notifyListeners();
    _persist();
  }

  void remove(String id) {
    _profiles.removeWhere((p) => p.id == id);
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
