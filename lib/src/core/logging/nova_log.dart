import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Which half of Nova a line came from.
///
/// They are kept apart on purpose. "It says connected but nothing loads" is
/// answered by two completely different pieces of evidence: what Nova decided
/// (which config, which node, which fingerprint) and what the sing-box core saw
/// on the wire. Interleaving them into one stream is how a support thread ends
/// up quoting the wrong half.
enum NovaLogSource { app, core }

/// Severity as reported by the core, or chosen by the app.
enum NovaLogLevel { debug, info, warn, error }

extension NovaLogLevelName on NovaLogLevel {
  String get label => switch (this) {
        NovaLogLevel.debug => 'DEBUG',
        NovaLogLevel.info => 'INFO',
        NovaLogLevel.warn => 'WARN',
        NovaLogLevel.error => 'ERROR',
      };
}

class NovaLogEntry {
  NovaLogEntry({
    required this.time,
    required this.source,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final NovaLogSource source;
  final NovaLogLevel level;
  final String message;

  /// `HH:MM:SS.mmm`, which is the resolution that matters when correlating a
  /// handshake failure with the reconnect that caused it.
  String get clock {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${time.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  String toString() => '$clock  ${level.label.padRight(5)}  $message';
}

/// The app's in-memory log.
///
/// Deliberately memory-only and bounded: a VPN client's log is the most
/// sensitive file it could possibly write, and a user who hits a problem needs
/// the last few minutes, not a history. Nothing here is persisted, so closing
/// the app discards it.
class NovaLog extends ChangeNotifier {
  NovaLog._();

  static final NovaLog instance = NovaLog._();

  /// Per-source cap. Roughly a few minutes of a talkative core, and small enough
  /// that holding it costs nothing worth measuring.
  static const int maxLines = 2000;

  final Queue<NovaLogEntry> _app = Queue<NovaLogEntry>();
  final Queue<NovaLogEntry> _core = Queue<NovaLogEntry>();

  /// The core can emit a burst of lines in a single frame (start-up, a rule-set
  /// load, a reconnect). Coalescing the notifications keeps that from turning
  /// into a rebuild per line while the log screen is open.
  Timer? _coalesce;
  bool _dirty = false;

  List<NovaLogEntry> lines(NovaLogSource source) =>
      List<NovaLogEntry>.unmodifiable(
          source == NovaLogSource.app ? _app : _core);

  int count(NovaLogSource source) =>
      source == NovaLogSource.app ? _app.length : _core.length;

  /// Records something Nova itself did. Keep these the decisions a user or a
  /// maintainer would want to reconstruct, and never put a credential in one.
  void write(String message, {NovaLogLevel level = NovaLogLevel.info}) =>
      _add(NovaLogSource.app, level, message);

  /// Records one line from the sing-box core, as the core wrote it.
  void writeCore(String message, {NovaLogLevel level = NovaLogLevel.info}) =>
      _add(NovaLogSource.core, level, message);

  void _add(NovaLogSource source, NovaLogLevel level, String message) {
    final String text = stripAnsi(message).trim();
    if (text.isEmpty) return;
    final Queue<NovaLogEntry> q = source == NovaLogSource.app ? _app : _core;
    q.addLast(NovaLogEntry(
      time: DateTime.now(),
      source: source,
      level: level,
      message: text,
    ));
    while (q.length > maxLines) {
      q.removeFirst();
    }
    _schedule();
  }

  void _schedule() {
    _dirty = true;
    _coalesce ??= Timer(const Duration(milliseconds: 250), () {
      _coalesce = null;
      if (!_dirty) return;
      _dirty = false;
      notifyListeners();
    });
  }

  void clear(NovaLogSource source) {
    (source == NovaLogSource.app ? _app : _core).clear();
    notifyListeners();
  }

  /// The log as text, ready to be copied into a support message.
  ///
  /// Every value that could identify or impersonate the user is masked first.
  /// This is the whole reason sharing is safe to offer: a raw sing-box log names
  /// the servers and can carry the UUID that *is* the user's subscription.
  String export(NovaLogSource source) =>
      lines(source).map((NovaLogEntry e) => redact(e.toString())).join('\n');

  /// Masks credentials in a log line.
  ///
  /// A UUID is a VLESS password, a long opaque token is usually a subscription
  /// key, and `user:pass@host` speaks for itself. Addresses are left alone: they
  /// are the thing being diagnosed, and the user already knows them.
  static String redact(String line) {
    return line
        .replaceAll(_uuid, '<uuid>')
        .replaceAllMapped(_userInfo, (Match m) => '<credentials>@')
        .replaceAllMapped(_token, (Match m) => '${m[1]}<token>');
  }

  /// Removes the terminal colour codes the core wraps its level and tags in.
  ///
  /// sing-box colourises for a TTY, and libbox hands those bytes through
  /// untouched, so on a phone every line arrived as
  /// `<esc>[36mINFO<esc>[0m ...` and the screen was unreadable. The desktop path
  /// already stripped them from the process output; doing it here covers every
  /// platform, including the libbox stream the mobile hosts feed in.
  /// Two passes: complete CSI sequences, then any escape byte left over. The
  /// second pass matters because the stream is not guaranteed to be well formed
  /// (a batch can be cut mid-sequence), and a stray escape renders as a box.
  static String stripAnsi(String s) =>
      s.replaceAll(_ansi, '').replaceAll(_escape, '');

  /// CSI sequences: ESC, '[', parameters, a final letter. Anchored on the
  /// escape byte so a log line that merely contains brackets keeps them.
  static final RegExp _ansi = RegExp('\\u001b\\[[0-9;]*[a-zA-Z]');

  static final RegExp _escape = RegExp('\\u001b');

  static final RegExp _uuid = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );

  /// `scheme://user:pass@host`
  static final RegExp _userInfo = RegExp(r'(?<=//)[^/@\s:]+:[^/@\s]+@');

  /// `token=…`, `password=…`, `secret=…`, `auth=…` in a URL or a log field.
  static final RegExp _token = RegExp(
    r'\b(token=|password=|passwd=|secret=|auth=|key=)[^\s&"]+',
    caseSensitive: false,
  );

  @override
  void dispose() {
    _coalesce?.cancel();
    super.dispose();
  }
}

/// Maps the core's numeric level onto Nova's.
///
/// sing-box uses logrus levels, where lower is more severe (panic 0 … trace 6).
NovaLogLevel novaLogLevelFromCore(int level) {
  if (level <= 2) return NovaLogLevel.error; // panic, fatal, error
  if (level == 3) return NovaLogLevel.warn;
  if (level == 4) return NovaLogLevel.info;
  return NovaLogLevel.debug; // debug, trace
}
