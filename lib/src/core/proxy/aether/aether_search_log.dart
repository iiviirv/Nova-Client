import 'dart:io';

import 'aether_options.dart';

/// How a gateway search describes itself in the log.
///
/// Kept apart from the search so the wording and, more importantly, the
/// decision about what is safe to write down can be tested without the native
/// core, which cannot be loaded on a test host at all. The search itself is
/// FFI from its first line, so anything left inside it is untestable by
/// construction.
abstract final class AetherSearchLog {
  /// The settings a search actually ran with.
  ///
  /// Worth writing down because the first question about any failure is
  /// whether the person was testing what they thought they were testing, and
  /// the second is what a working platform had set differently.
  static String settings(AetherOptions o) =>
      'mode=${o.mode.name}, transport=${o.transport.name}, ip=${o.ip.name}, '
      'scan=${o.scan.name}, noize=${o.noize?.name ?? 'auto'}';

  /// Which platform produced the line, so logs from two devices can be told
  /// apart once they are pasted into the same thread.
  static String platform() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  /// What a finished verification records.
  ///
  /// The rule worth having in one testable place is the address. `ip` is only
  /// a Cloudflare exit when the traffic actually went through WARP. When it did
  /// not, the same field holds the user's own address, and this map is written
  /// to a log the app invites them to export and paste into a support thread.
  /// Publishing "this residential address runs Nova" is the worst thing this
  /// app could emit, and it would happen only in the failure case, which is the
  /// case people report.
  ///
  /// `warp` is kept either way, so a leak is still diagnosable without naming
  /// the person who hit it.
  static Map<String, dynamic> proof({
    required bool viaWarp,
    required int ms,
    String? warp,
    String? ip,
  }) =>
      <String, dynamic>{
        'reachable': viaWarp,
        if (warp != null) 'warp': warp,
        if (viaWarp && ip != null) 'exit_ip': ip,
        'ms': ms,
      };

  /// The scalar fields of a core result, for the log.
  ///
  /// Only small, plainly non-secret values are written out. A shared log is the
  /// most sensitive thing this app can produce, and widening it to chase one
  /// bug is not a trade worth making: anything nested, long, or named like a
  /// credential is reported by name only. The core's result maps are not a
  /// fixed shape, so this has to be safe for a key nobody has seen yet, which
  /// is why the rule is a denylist on the name plus a ceiling on the length
  /// rather than a list of fields known to be fine.
  static String fields(Map<String, dynamic>? result) {
    if (result == null || result.isEmpty) return '{}';
    final List<String> out = <String>[];
    for (final MapEntry<String, dynamic> e in result.entries) {
      final Object? v = e.value;
      if (secretish.hasMatch(e.key)) {
        out.add('${e.key}=<hidden>');
      } else if (v is bool || v is num) {
        out.add('${e.key}=$v');
      } else if (v is String && v.length <= maxValue) {
        out.add('${e.key}=$v');
      } else {
        out.add('${e.key}=<${v.runtimeType}>');
      }
    }
    return '{${out.join(', ')}}';
  }

  /// Longest string value written out in full.
  ///
  /// This was 120 on the reasoning that a WARP key is longer. It is not: a
  /// WireGuard key in base64 is 44 characters and a WARP subscription key is
  /// 26, so both sailed under the old ceiling. Every field actually worth
  /// reading in a log (a state, a short reason, an address) fits in 48.
  static const int maxValue = 48;

  /// Field names whose values never go in the log, whatever they hold.
  /// Field names whose values never reach the log, whatever they hold.
  ///
  /// `license` is the one that matters most and was missing: it is what the
  /// WARP API calls a transferable subscription credential, and it sits in the
  /// registration response as a plain sibling of `token`.
  static final RegExp secretish = RegExp(
      r'key|secret|token|priv|pass|seed|licen[cs]e|cred|jwt|bearer|session|'
      r'cookie|sig|auth|account',
      caseSensitive: false);

  /// A string that came from outside Dart, made safe to log.
  ///
  /// The careful filtering in [fields] only ever guarded a map Nova builds
  /// itself. The strings that are genuinely untrusted, the core's own error
  /// text, went straight to the log uncapped and unexamined, where a refusal
  /// that quotes the config it rejected would take the credential with it.
  static String scrub(String? text) {
    if (text == null) return '';
    String out = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Anything shaped like a key, wherever it sits in the sentence.
    out = out.replaceAll(
        RegExp(r'\b[A-Za-z0-9+/]{32,}={0,2}\b'), '<hidden>');
    out = out.replaceAllMapped(
        RegExp(r'("?)(\w*(?:key|secret|token|licen[cs]e|pass|auth)\w*)\1'
            r'\s*[:=]\s*"?([^",}\s]+)"?',
            caseSensitive: false),
        (Match m) => '${m[2]}=<hidden>');
    return out.length <= maxError ? out : '${out.substring(0, maxError - 3)}...';
  }

  /// Longest core-supplied message kept. Long enough to diagnose, short enough
  /// that a core which decides to print a whole struct cannot fill the log.
  static const int maxError = 200;
}
