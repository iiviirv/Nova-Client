import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// What the bundled native core can actually do, asked of the core itself.
///
/// The failure this exists to prevent: `AwgConfig.toEndpoint` has emitted a
/// complete AmneziaWG (`awg`) endpoint, junk parameters and all, since the
/// config layer was written, while the shipped core was stock sing-box with no
/// AmneziaWG in it. Both halves looked right in isolation, the customer's QR
/// worked in the official Amnezia apps, and Nova's own app connected to
/// nothing. Nothing in the app noticed, because nothing ever asked.
///
/// So the host answers a `coreFeatures` call by handing its core a minimal
/// AmneziaWG endpoint and reporting whether the core could build it. The answer
/// is a property of the binary, so it is fetched once and cached.
///
/// A host that does not implement the call (iOS, macOS, Windows, Linux, or a
/// test harness) yields [awgUnknown] rather than a verdict, and an unknown
/// answer never blocks a connection: the point is to make a mismatch visible
/// where it can be seen, not to refuse to work where it cannot be measured.
class CoreFeatures {
  CoreFeatures({MethodChannel? control})
      : _control = control ?? const MethodChannel('nova.proxy/control');

  /// The instance the proxy controller uses. Tests build their own.
  static final CoreFeatures instance = CoreFeatures();

  final MethodChannel _control;

  bool? _awg;
  String? _awgReason;
  String? _coreVersion;
  Future<void>? _inFlight;

  /// True when the core answered that it cannot build an AmneziaWG endpoint.
  /// False both when it can and when nobody could be asked (see [awgUnknown]).
  bool get awgUnsupported => _awg == false;

  /// True while no host has answered, so no claim either way can be made.
  bool get awgUnknown => _awg == null;

  /// The core's own reason for refusing AmneziaWG, when it gave one.
  String? get awgReason => _awgReason;

  /// The core's version string, empty until the host has been asked.
  String get coreVersion => _coreVersion ?? '';

  /// Ask the host once, and remember the answer. Never throws: a host that
  /// cannot answer leaves the verdict unknown.
  Future<void> load() async {
    if (_awg != null) return;
    return _inFlight ??= _load();
  }

  Future<void> _load() async {
    try {
      // Bounded: this runs inside connect(), before the watchdog is armed, so
      // a host that never answers would leave the UI on "Connecting" forever.
      final Map<Object?, Object?>? info = await _control
          .invokeMethod<Map<Object?, Object?>>('coreFeatures')
          .timeout(const Duration(seconds: 8));
      if (info == null) return;
      final Object? awg = info['amneziawg'];
      if (awg is bool) _awg = awg;
      final Object? reason = info['amneziawgReason'];
      if (reason is String && reason.isNotEmpty) _awgReason = reason;
      final Object? version = info['coreVersion'];
      if (version is String) _coreVersion = version;
    } catch (_) {
      // MissingPluginException on a host that has no probe yet, or any other
      // channel failure. Both leave the verdict unknown on purpose.
    } finally {
      _inFlight = null;
    }
  }

  /// The message shown when a config needs AmneziaWG and the core says it has
  /// none. It names the cause, because the symptom (a tunnel that connects and
  /// carries nothing) sends people to the server instead.
  String get awgUnsupportedMessage {
    final String reason = _awgReason == null ? '' : ' Core said: $_awgReason';
    return "This build's VPN core has no AmneziaWG support, so an AmneziaWG "
        'server cannot be used here. Update Nova to a build whose core '
        'includes it, or use one of this server\'s other protocols.$reason';
  }

  /// True when [configJson] asks for an AmneziaWG endpoint. Reads the document
  /// the core is about to be given, rather than re-deriving the decision from
  /// the node, so a config assembled by any path is covered.
  static bool usesAwg(String configJson) => _usesType(configJson, 'awg');

  /// True when [configJson] asks for a NaiveProxy outbound.
  static bool usesNaive(String configJson) => _usesType(configJson, 'naive');

  static bool _usesType(String configJson, String type) {
    try {
      final Object? doc = jsonDecode(configJson);
      if (doc is! Map) return false;
      for (final String key in const <String>['endpoints', 'outbounds']) {
        final Object? list = doc[key];
        if (list is! List) continue;
        for (final Object? entry in list) {
          if (entry is Map && entry['type'] == type) return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The message shown when a config needs NaiveProxy and the core has none.
  ///
  /// This is a real, shipped split rather than a hypothetical: the Android and
  /// Apple cores are built with `with_naive_outbound`, and the bundled desktop
  /// sing-box binary is not (it answers `sing-box check` with "naive outbound is
  /// not included in this build"). Without this the desktop core simply refuses
  /// to start and the user sees "the core did not come up in time".
  String get naiveUnsupportedMessage =>
      "This build's VPN core has no NaiveProxy support, so a NaiveProxy server "
      'cannot be used here. Use one of this server\'s other protocols, or '
      'connect from the phone app.';
}
