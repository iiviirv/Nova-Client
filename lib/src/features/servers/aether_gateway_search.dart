import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/proxy/aether/aether_core.dart';
import '../../core/proxy/aether/aether_gateway_finder.dart';
import '../../core/proxy/aether/aether_options.dart';
import '../../core/proxy/aether/aether_protocol.dart';
import '../../core/proxy/aether/aether_tunnel.dart';

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
  /// [excludedFirst] seeds the ruled-out list. A replacement search starts
  /// with the address that just failed already excluded, because a search that
  /// does not exclude it tends to return it again.
  Future<AetherFindResult> run(
    AetherOptions options,
    ValueChanged<AetherSearchProgress> onProgress, {
    List<String> excludedFirst,
  });

  /// Checks one address the user typed, without searching for others.
  ///
  /// Requiring a search before Save would otherwise take away hand-entered
  /// gateways entirely: someone handed a working address has no way to use it,
  /// because the only route to a saved config is a sweep that may not pick
  /// theirs. This gives the same proof for an address they already have, and
  /// is far quicker than a scan since there is only one candidate.
  Future<bool> verifyAddress(AetherOptions options, String endpoint);

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
    ValueChanged<AetherSearchProgress> onProgress, {
    List<String> excludedFirst = const <String>[],
  }) async {
    _cancelled = false;
    final AetherCore core = AetherCore.open();
    _core = core;

    // A path prefix, not a directory: the core appends the transport, so this
    // becomes aether-masque (and aether-masque-lastconn) beside it.
    final Directory dir = await getApplicationSupportDirectory();
    final AetherJobStatus opened = await _await(
        core, core.identityOpen(options, base: '${dir.path}/aether'));
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
    // Seed what is already known dead, so a replacement search does not offer
    // the address that just failed back again.
    for (final String dead in excludedFirst) {
      if (dead.isNotEmpty && !finder.rejected.contains(dead)) {
        finder.rejected.add(dead);
      }
    }
    return finder.find(options);
  }

  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async {
    if (endpoint.trim().isEmpty) return false;
    final AetherCore core = AetherCore.open();
    final Directory dir = await getApplicationSupportDirectory();
    final AetherJobStatus opened = await _await(
        core, core.identityOpen(options, base: '${dir.path}/aether'));
    if (opened.state != AetherJobState.done) return false;
    final Object? handle = opened.result?[kAetherIdentityField];
    if (handle is! num) return false;

    final int port = await AetherTunnel.freeLoopbackPort();
    final AetherJobStatus proof = await _await(
        core,
        core.verifyStart(handle.toInt(), options,
            endpoint: endpoint.trim(), socks: '127.0.0.1:$port'));
    // The same two-part answer the finder reads: the state says the check ran,
    // `reachable` says what it concluded. Only an explicit false is a refusal,
    // so a core that does not report the field is still trusted.
    return proof.state == AetherJobState.done &&
        proof.result?['reachable'] != false;
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
  /// Confirmed on a device: an opened identity returns
  /// `{identity: 2, summary: {...}, path: ..., ok: true}`.
  ///
  /// This used to try three likely spellings and then fall back to any lone
  /// integer in the result. That was the right thing while the key was unknown,
  /// and the wrong thing to keep: a fallback that always finds something cannot
  /// report that the shape changed, it just returns a number that no longer
  /// means what it did. Now it reads the field, and says so when it is missing.
  static int? _handleOf(Map<String, dynamic>? result) =>
      _asInt(result?[kAetherIdentityField]);

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
