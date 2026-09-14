import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/proxy/aether/aether_core.dart';
import '../../core/proxy/aether/aether_gateway_finder.dart';
import '../../core/proxy/aether/aether_options.dart';
import '../../core/proxy/aether/aether_protocol.dart';

/// Where a gateway search has got to, so the editor can say it out loud.
///
/// The competing client asks for a two-minute wait behind a bare spinner and
/// then hands back one address to accept or reject. The numbers here are what
/// turn that into something a person can read: which address is being tried,
/// what is being done to it, and how many have already been ruled out.
@immutable
class AetherSearchProgress {
  const AetherSearchProgress({
    required this.attempt,
    required this.verifying,
    required this.ruledOut,
  });

  /// Which gateway this is, counting from one.
  final int attempt;

  /// False while scanning for an address, true while proving it carries
  /// traffic. Two very different waits, so they are not one word.
  final bool verifying;

  /// How many addresses answered a probe but carried nothing.
  final int ruledOut;
}

/// Runs a gateway search on behalf of the editor.
///
/// An interface rather than a function so a widget test can drive every state
/// (running, cancelled, found, failed) without the native core, which cannot be
/// loaded on the test host at all.
abstract class AetherGatewaySearch {
  /// False when this build ships no Aether core, so the screen can say so
  /// instead of offering a button that fails.
  bool get available;

  /// Finds a gateway that carries traffic, reporting progress as it goes.
  Future<AetherFindResult> run(
    AetherOptions options,
    ValueChanged<AetherSearchProgress> onProgress,
  );

  /// Stops the search. The in-flight [run] still completes, with [cancelled]
  /// set, because the core's job has to be told before anything can be
  /// reported.
  void cancel();

  /// True when the last [run] ended because [cancel] was called. A stopped
  /// search is not a failed one and must not be shown as an error.
  bool get cancelled;
}

/// The real search, against the Aether core over FFI.
class AetherCoreSearch implements AetherGatewaySearch {
  AetherCoreSearch({
    this.attempts = 4,
    this.pollEvery = const Duration(milliseconds: 500),
  });

  /// How many gateways to try before giving up, passed to the finder.
  final int attempts;

  /// How often a running job is polled. Long enough not to spin the FFI
  /// boundary, short enough that Cancel feels immediate.
  final Duration pollEvery;

  AetherCore? _core;
  int? _job;
  bool _cancelled = false;

  @override
  bool get available => AetherCore.available;

  @override
  bool get cancelled => _cancelled;

  @override
  void cancel() {
    _cancelled = true;
    final AetherCore? core = _core;
    final int? job = _job;
    // Cancelling the job matters more than the flag: without it the core keeps
    // sweeping for the rest of its budget after the user has walked away.
    if (core != null && job != null) core.jobCancel(job);
  }

  @override
  Future<AetherFindResult> run(
    AetherOptions options,
    ValueChanged<AetherSearchProgress> onProgress,
  ) async {
    _cancelled = false;
    final AetherCore core = AetherCore.open();
    _core = core;

    final Directory dir = await getApplicationSupportDirectory();
    final AetherJobStatus opened =
        await _await(core, core.identityOpen(options, dir: dir.path));
    if (opened.state != AetherJobState.done) {
      return AetherFindResult(
          endpoint: null,
          error: opened.error ?? 'the WARP identity could not be opened',
          attempts: 0,
          rejected: const <String>[]);
    }
    final int? identity = _handleOf(opened.result);
    if (identity == null) {
      return const AetherFindResult(
          endpoint: null,
          error: 'the core opened an identity but returned no handle for it',
          attempts: 0,
          rejected: <String>[]);
    }

    int attempt = 0;
    late final AetherGatewayFinder finder;
    finder = AetherGatewayFinder(
      attempts: attempts,
      scan: (AetherOptions o, List<String> excluded) async {
        attempt += 1;
        onProgress(AetherSearchProgress(
            attempt: attempt,
            verifying: false,
            ruledOut: finder.rejected.length));
        return _await(core, core.scanStart(identity, o, excluded: excluded));
      },
      verify: (AetherOptions o, String endpoint) async {
        onProgress(AetherSearchProgress(
            attempt: attempt,
            verifying: true,
            ruledOut: finder.rejected.length));
        final int port = await _freeLoopbackPort();
        // A scratch port, never the one a live tunnel serves on, so proving an
        // address cannot collide with a connection the user is using.
        //
        // The endpoint is passed directly now. It used to ride on the options
        // instead, because the payload builder had no field for it, and that
        // was a real hole: the core's tunnel payload requires `peer`, so
        // verification would have been refused outright rather than quietly
        // proving the wrong address.
        return _await(
            core,
            core.verifyStart(identity, o,
                endpoint: endpoint, socks: '127.0.0.1:$port'));
      },
    );
    return finder.find(options);
  }

  /// Polls a started job to completion. A start reply that is not ok never had
  /// a job to poll, so it is turned into a failed status rather than polled.
  Future<AetherJobStatus> _await(AetherCore core, AetherReply started) async {
    if (!started.ok) {
      return AetherJobStatus(AetherJobState.failed, error: started.error);
    }
    final int? job = _asInt(started['job']);
    if (job == null) {
      return const AetherJobStatus(AetherJobState.failed,
          error: 'the core started something without saying what');
    }
    _job = job;
    try {
      while (true) {
        if (_cancelled) {
          return const AetherJobStatus(AetherJobState.failed,
              error: 'cancelled');
        }
        final AetherJobStatus s = core.jobPoll(job);
        if (!s.isRunning) return s;
        await Future<void>.delayed(pollEvery);
      }
    } finally {
      _job = null;
    }
  }

  /// The identity handle out of the job's result.
  ///
  /// The core's own name for this field is not recorded anywhere in this repo,
  /// so the known spellings are tried and anything else falls back to the one
  /// integer in the result. When a device run confirms the real key, this is
  /// the single place to pin it: the alternative was to guess one spelling and
  /// have every later call fail with "there is no identity".
  static int? _handleOf(Map<String, dynamic>? result) {
    if (result == null) return null;
    for (final String key in <String>['identity', 'handle', 'id']) {
      final int? v = _asInt(result[key]);
      if (v != null) return v;
    }
    for (final MapEntry<String, dynamic> e in result.entries) {
      if (e.key == 'ok') continue;
      final int? v = _asInt(e.value);
      if (v != null) return v;
    }
    return null;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  /// A free loopback port for the verification tunnel, borrowed the same way
  /// the measuring core picks one.
  static Future<int> _freeLoopbackPort() async {
    final ServerSocket s =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int port = s.port;
    await s.close();
    return port;
  }
}
