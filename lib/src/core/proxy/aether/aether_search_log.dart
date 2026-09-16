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

  /// Longest string value written out in full. A WARP key is longer than this,
  /// and so is anything base64, while every field worth reading in a log
  /// (a state, a reason, an address) is far shorter.
  static const int maxValue = 120;

  /// Field names whose values never go in the log, whatever they hold.
  static final RegExp secretish =
      RegExp(r'key|secret|token|priv|pass|seed', caseSensitive: false);
}
