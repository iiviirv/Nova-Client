import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../features/cloudflare/doh_resolver.dart';
import '../../features/cloudflare/secure_http.dart';

/// Per-ISP client optimization.
///
/// Iran's DPI treats carriers differently: the TLS ClientHello that blends in on
/// Irancell (Chrome uTLS) is not the one that survives on MCI, and fragmentation
/// helps on some networks and hurts on others. The Nova server publishes a
/// carrier -> settings map at `GET /isp-profile`; this client detects which
/// carrier the phone is on (SIM MCC-MNC) and applies the matching fingerprint and
/// fragmentation before the tunnel is built.
///
/// Everything degrades gracefully: detection failing, the profile fetch failing,
/// or no rule matching all fall back to the built-in default (Chrome, no forced
/// fragment change), so a connect is never blocked on this.
class IspSettings {
  const IspSettings({this.fingerprint, this.tlsFragment, this.mux, this.mtu});

  final String? fingerprint;
  final bool? tlsFragment;
  final bool? mux;
  final int? mtu;

  factory IspSettings.fromJson(Map<String, dynamic> j) => IspSettings(
        fingerprint: (j['fingerprint'] as String?)?.trim().isNotEmpty == true
            ? (j['fingerprint'] as String).trim()
            : null,
        tlsFragment: j['tlsFragment'] is bool ? j['tlsFragment'] as bool : null,
        mux: j['mux'] is bool ? j['mux'] as bool : null,
        mtu: j['mtu'] is num ? (j['mtu'] as num).toInt() : null,
      );
}

class IspRule {
  const IspRule({
    required this.label,
    required this.mccmnc,
    required this.asn,
    required this.settings,
  });

  final String label;
  final List<String> mccmnc;
  final List<String> asn;
  final IspSettings settings;

  factory IspRule.fromJson(Map<String, dynamic> j) => IspRule(
        label: (j['label'] as String?) ?? '',
        mccmnc: _strList(j['mccmnc']),
        asn: _strList(j['asn']),
        settings: j['settings'] is Map<String, dynamic>
            ? IspSettings.fromJson(j['settings'] as Map<String, dynamic>)
            : const IspSettings(),
      );
}

class IspProfile {
  const IspProfile({
    required this.version,
    required this.defaults,
    required this.isps,
  });

  final int version;
  final IspSettings defaults;
  final List<IspRule> isps;

  factory IspProfile.fromJson(Map<String, dynamic> j) => IspProfile(
        version: j['version'] is num ? (j['version'] as num).toInt() : 1,
        defaults: j['default'] is Map<String, dynamic>
            ? IspSettings.fromJson(j['default'] as Map<String, dynamic>)
            : const IspSettings(fingerprint: 'chrome', tlsFragment: false),
        isps: (j['isps'] is List)
            ? (j['isps'] as List)
                .whereType<Map<String, dynamic>>()
                .map(IspRule.fromJson)
                .toList()
            : const <IspRule>[],
      );
}

/// The resolved settings for the phone's current carrier.
class IspMatch {
  const IspMatch({
    required this.fingerprint,
    required this.tlsFragment,
    required this.label,
    required this.source,
  });

  /// The uTLS fingerprint to force, or null to keep each node's own value.
  final String? fingerprint;

  /// Whether ClientHello fragmentation should be on. Null means "leave the app
  /// default untouched" so a carrier with no opinion doesn't override it.
  final bool? tlsFragment;

  /// The matched carrier label (or "Default") for display.
  final String label;

  /// Where the answer came from: 'carrier', 'default', or 'off'.
  final String source;

  static const IspMatch off =
      IspMatch(fingerprint: null, tlsFragment: null, label: '', source: 'off');
}

/// The built-in profile, identical to the server's DEFAULT_ISP_PROFILE. Used when
/// the network fetch has not happened or failed, so the feature works on first
/// launch and offline.
const Map<String, dynamic> kBuiltinIspProfileJson = <String, dynamic>{
  'version': 1,
  'default': <String, dynamic>{
    'fingerprint': 'chrome',
    'tlsFragment': false,
    'mux': false,
    'mtu': 1280,
  },
  'isps': <Map<String, dynamic>>[
    <String, dynamic>{
      'label': 'Irancell (MTN)',
      'mccmnc': <String>['43235'],
      'asn': <String>['44244'],
      'settings': <String, dynamic>{'fingerprint': 'chrome', 'tlsFragment': true},
    },
    <String, dynamic>{
      'label': 'MCI (Hamrah-e Aval)',
      'mccmnc': <String>['43211'],
      'asn': <String>['197207'],
      'settings': <String, dynamic>{
        'fingerprint': 'randomized',
        'tlsFragment': true,
      },
    },
    <String, dynamic>{
      'label': 'Rightel',
      'mccmnc': <String>['43220'],
      'asn': <String>['57218'],
      'settings': <String, dynamic>{'fingerprint': 'firefox', 'tlsFragment': true},
    },
    <String, dynamic>{
      'label': 'Shatel',
      'asn': <String>['31549'],
      'settings': <String, dynamic>{'fingerprint': 'chrome', 'tlsFragment': false},
    },
    <String, dynamic>{
      'label': 'MobinNet',
      'asn': <String>['50810'],
      'settings': <String, dynamic>{'fingerprint': 'chrome', 'tlsFragment': true},
    },
  ],
};

class IspOptimizer {
  IspOptimizer._();
  static final IspOptimizer instance = IspOptimizer._();

  static const MethodChannel _channel = MethodChannel('nova.proxy/control');

  // A freshly fetched profile overrides the built-in one for [_fetchTtl].
  IspProfile _profile = IspProfile.fromJson(kBuiltinIspProfileJson);
  DateTime? _fetchedAt;
  static const Duration _fetchTtl = Duration(hours: 6);

  /// The last resolved match, exposed so the UI can show what is being applied
  /// without re-running detection.
  IspMatch lastMatch = IspMatch.off;

  /// Detect the carrier and resolve the settings to apply.
  ///
  /// [host] is the Nova host to pull a fresh profile from (the user's own worker
  /// or node, so admin overrides are honored). When null/empty the built-in
  /// profile is used. [enabled] false short-circuits to [IspMatch.off] so the app
  /// keeps each node's own fingerprint and its default fragmentation.
  Future<IspMatch> resolve({
    required bool enabled,
    String? host,
    http.Client? client,
  }) async {
    if (!enabled) {
      lastMatch = IspMatch.off;
      return lastMatch;
    }
    await _maybeFetch(host, client);
    final _CarrierInfo carrier = await _detectCarrier();
    final IspMatch m = _match(carrier);
    lastMatch = m;
    if (kDebugMode) {
      debugPrint('[IspOptimizer] carrier=${carrier.mccMnc}'
          ' name="${carrier.name}" -> ${m.label}'
          ' fp=${m.fingerprint ?? '(node)'} frag=${m.tlsFragment ?? '(app)'}'
          ' src=${m.source}');
    }
    return m;
  }

  IspMatch _match(_CarrierInfo carrier) {
    final String code = carrier.mccMnc;
    if (code.isNotEmpty) {
      for (final IspRule r in _profile.isps) {
        if (r.mccmnc.contains(code)) {
          return _fromSettings(r.settings, r.label, 'carrier');
        }
      }
    }
    // Fuzzy name match as a fallback when MCC-MNC is unavailable (e.g. some
    // Wi-Fi-only states still report an operator name).
    final String name = carrier.name.toLowerCase();
    if (name.isNotEmpty) {
      for (final IspRule r in _profile.isps) {
        final String key = r.label.toLowerCase().split(' ').first;
        if (key.length >= 3 && name.contains(key)) {
          return _fromSettings(r.settings, r.label, 'carrier');
        }
      }
    }
    return _fromSettings(_profile.defaults, 'Default', 'default');
  }

  IspMatch _fromSettings(IspSettings s, String label, String source) => IspMatch(
        fingerprint: s.fingerprint,
        tlsFragment: s.tlsFragment,
        label: label,
        source: source,
      );

  Future<void> _maybeFetch(String? host, http.Client? injected) async {
    final String h = (host ?? '').trim();
    if (h.isEmpty) return;
    final DateTime? at = _fetchedAt;
    if (at != null && DateTime.now().difference(at) < _fetchTtl) return;
    final http.Client c = injected ?? _defaultClient();
    try {
      final Uri uri = Uri.parse('https://$h/isp-profile');
      final http.Response r =
          await c.get(uri).timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final dynamic body = jsonDecode(r.body);
        if (body is Map<String, dynamic>) {
          _profile = IspProfile.fromJson(body);
          _fetchedAt = DateTime.now();
        }
      }
    } catch (_) {
      // Best-effort: keep whatever profile we already have (built-in or a prior
      // fetch). A censored/offline network must not block the connect.
    } finally {
      if (injected == null) c.close();
    }
  }

  http.Client _defaultClient() {
    final DohResolver doh = DohResolver();
    return buildSecureClient((Uri uri) async {
      // System DNS first (fast, works on open networks), DoH as the censored-
      // network fallback. A wrong IP fails closed on the TLS handshake because
      // buildSecureClient always presents the real hostname as SNI.
      try {
        final List<InternetAddress> sys =
            await InternetAddress.lookup(uri.host).timeout(
          const Duration(seconds: 4),
        );
        final InternetAddress? v4 = sys.cast<InternetAddress?>().firstWhere(
              (InternetAddress? a) => a?.type == InternetAddressType.IPv4,
              orElse: () => null,
            );
        if (v4 != null) return v4;
      } catch (_) {}
      final List<String> ips = await doh.resolveA(uri.host);
      if (ips.isNotEmpty) return InternetAddress(ips.first);
      throw const SocketException('isp-profile: host did not resolve');
    });
  }

  Future<_CarrierInfo> _detectCarrier() async {
    // Android reads TelephonyManager; iOS reads CoreTelephony (which returns a
    // usable code only on older iOS - modern iOS reports 65535, handled natively
    // by returning an empty map -> the default profile).
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const _CarrierInfo('', '');
    }
    try {
      final Object? res = await _channel.invokeMethod('networkInfo');
      if (res is Map) {
        final String code =
            (res['mccMnc'] ?? res['sim'] ?? '').toString().trim();
        final String name = (res['name'] ?? '').toString().trim();
        return _CarrierInfo(code, name);
      }
    } on MissingPluginException {
      // Older host build without the networkInfo method: fall back to default.
    } catch (_) {}
    return const _CarrierInfo('', '');
  }
}

class _CarrierInfo {
  const _CarrierInfo(this.mccMnc, this.name);
  final String mccMnc;
  final String name;
}

List<String> _strList(Object? v) {
  if (v is List) {
    return v.map((Object? e) => e.toString().trim()).where((String s) => s.isNotEmpty).toList();
  }
  return const <String>[];
}
