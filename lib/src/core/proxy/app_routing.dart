import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the per-app proxy list is read.
enum AppRoutingMode {
  /// Every app goes through Nova. The list is ignored.
  all,

  /// Only the listed apps go through Nova; everything else keeps its normal
  /// connection.
  only,

  /// Every app goes through Nova except the listed ones.
  except,
}

/// One installed app, as the picker shows it.
@immutable
class InstalledApp {
  const InstalledApp({required this.package, required this.label, this.icon});

  final String package;
  final String label;

  /// The launcher icon as PNG bytes, or null when it could not be rasterised.
  final Uint8List? icon;
}

/// Per-app proxy: which apps Nova carries, and which it leaves alone.
///
/// Android only. Its VpnService takes an allow or deny list of packages and the
/// core passes it straight through (see NovaVpnService.openTun). iOS reserves
/// per-app VPN for MDM-managed devices, and the desktop hosts have no equivalent
/// at this layer, so the setting is simply not offered there.
///
/// The two lists are mutually exclusive by construction: Android's
/// VpnService.Builder throws if a config uses both, so the mode decides which of
/// the two the config carries and the other is always empty.
class AppRouting extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('nova.proxy/control');

  static const String _modeKey = 'nova.apps.mode';
  static const String _listKey = 'nova.apps.list';

  SharedPreferences? _prefs;

  AppRoutingMode _mode = AppRoutingMode.all;
  AppRoutingMode get mode => _mode;

  Set<String> _packages = <String>{};
  Set<String> get packages => Set<String>.unmodifiable(_packages);

  /// True when the setting is actually doing something, so the UI can say
  /// "12 apps" rather than describing a list nothing reads.
  bool get isActive => _mode != AppRoutingMode.all && _packages.isNotEmpty;

  /// What the TUN inbound should carry. Empty unless the mode says otherwise.
  List<String> get includePackages =>
      _mode == AppRoutingMode.only ? _packages.toList() : const <String>[];

  List<String> get excludePackages =>
      _mode == AppRoutingMode.except ? _packages.toList() : const <String>[];

  void attachPrefs(SharedPreferences prefs) {
    _prefs = prefs;
    final String? m = prefs.getString(_modeKey);
    _mode = AppRoutingMode.values.firstWhere(
      (AppRoutingMode v) => v.name == m,
      orElse: () => AppRoutingMode.all,
    );
    _packages = (prefs.getStringList(_listKey) ?? const <String>[]).toSet();
    notifyListeners();
  }

  Future<void> setMode(AppRoutingMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _prefs?.setString(_modeKey, mode.name);
  }

  Future<void> toggle(String package, bool on) async {
    if (on ? !_packages.add(package) : !_packages.remove(package)) return;
    notifyListeners();
    await _prefs?.setStringList(_listKey, _packages.toList());
  }

  Future<void> clear() async {
    if (_packages.isEmpty) return;
    _packages = <String>{};
    notifyListeners();
    await _prefs?.setStringList(_listKey, const <String>[]);
  }

  /// The installed apps to choose from. Android only; anywhere else this is
  /// empty and the setting is not offered.
  Future<List<InstalledApp>> installedApps() async {
    try {
      final List<Object?>? raw =
          await _channel.invokeMethod<List<Object?>>('installedApps');
      if (raw == null) return const <InstalledApp>[];
      return <InstalledApp>[
        for (final Object? e in raw)
          if (e is Map)
            InstalledApp(
              package: (e['package'] as String?) ?? '',
              label: (e['label'] as String?) ?? (e['package'] as String?) ?? '',
              icon: e['icon'] as Uint8List?,
            ),
      ].where((InstalledApp a) => a.package.isNotEmpty).toList();
    } catch (_) {
      // No host handler (iOS, desktop) or the query failed: an empty list is
      // the honest answer and the screen says so.
      return const <InstalledApp>[];
    }
  }
}
