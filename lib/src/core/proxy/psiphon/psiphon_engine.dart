import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'psiphon_config.dart';
import 'psiphon_notices.dart';

/// Runs the Psiphon engine as its own process and waits until it can actually
/// carry traffic.
///
/// Desktop and Android share this. Both run the engine out of process, for the
/// same reason MasterDNS does: it is Go, sing-box is Go, and one process cannot
/// hold two Go runtimes. iOS cannot spawn anything at all and needs the engine
/// compiled into the core instead, which is not this class.
class PsiphonEngine {
  PsiphonEngine._(this._process, this._config);

  final Process _process;
  final PsiphonConfig _config;
  bool _exited = false;

  int get socksPort => _config.socksPort;
  bool get running => !_exited;

  /// Starts the engine and returns once a tunnel is up.
  ///
  /// [budget] is generous on purpose. Psiphon routinely takes a minute or more
  /// on a hostile network, and the Aether core allows it three. A short budget
  /// here would report failure on a connection that was seconds from working,
  /// which is exactly the bug that made MASQUE look broken in Iran.
  static Future<PsiphonEngine> start({
    required String binary,
    required PsiphonConfig config,
    required Directory workDir,
    Duration budget = const Duration(seconds: 180),
    Future<Process> Function(String exe, List<String> args)? spawn,
    void Function(String line)? log,
  }) async {
    final String? bad = config.problem;
    if (bad != null) throw PsiphonUnavailable(bad);

    final File conf = File('${workDir.path}/nova-psiphon.json');
    await conf.writeAsString(config.toJsonText(), flush: true);

    final Process proc = await (spawn ?? _spawn)(
      binary,
      <String>['-config', conf.path, '-dataRootDirectory', config.dataDir],
    );

    final engine = PsiphonEngine._(proc, config);
    unawaited(proc.exitCode.then((_) => engine._exited = true));

    final ready = Completer<void>();
    // Both streams are read. Psiphon writes notices to stderr in some builds
    // and stdout in others, and a reader that watches only one can sit through
    // a working connection seeing nothing.
    for (final Stream<List<int>> s in <Stream<List<int>>>[
      proc.stdout,
      proc.stderr,
    ]) {
      s
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) {
        final String? shown = PsiphonNotices.forLog(line);
        if (shown != null) log?.call(shown);
        if (!ready.isCompleted && PsiphonNotices.tunnelIsUp(line)) {
          ready.complete();
        }
      }, onError: (_) {});
    }

    // An engine that dies is not going to become ready, and waiting out the
    // whole budget to say so wastes three minutes of the user's evening.
    unawaited(proc.exitCode.then((int code) {
      if (!ready.isCompleted) {
        ready.completeError(
            PsiphonUnavailable('the engine stopped before it connected '
                '(exit $code)'));
      }
    }));

    try {
      await ready.future.timeout(budget, onTimeout: () {
        throw PsiphonUnavailable(
            'no Psiphon tunnel after ${budget.inSeconds} seconds');
      });
    } catch (_) {
      await engine.stop();
      rethrow;
    }
    return engine;
  }

  static Future<Process> _spawn(String exe, List<String> args) =>
      Process.start(exe, args);

  Future<void> stop() async {
    if (_exited) return;
    _process.kill();
    // Psiphon writes its server list on the way out, so it is given a moment
    // to do that rather than being killed outright. Losing it means the next
    // connection starts by fetching the list again.
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    }
    _exited = true;
  }
}

class PsiphonUnavailable implements Exception {
  PsiphonUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'Psiphon is unavailable: $reason';
}
