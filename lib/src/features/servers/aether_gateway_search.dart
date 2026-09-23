import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/logging/nova_log.dart';
import '../../core/proxy/aether/aether_core.dart';
import '../../core/proxy/aether/aether_gateway_finder.dart';
import '../../core/proxy/aether/aether_identity_recovery.dart';
import '../../core/proxy/aether/aether_options.dart';
import '../../core/proxy/aether/aether_protocol.dart';
import '../../core/proxy/aether/aether_search_log.dart';
import '../../core/proxy/aether/aether_traffic_check.dart';
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
    this.usingFallback = false,
    this.mode,
  });

  /// Which gateway this is, counting from one.
  final int attempt;

  /// False while scanning for an address, true while proving it carries
  /// traffic. Two very different waits, so they are not one word.
  final bool verifying;

  /// How many addresses answered a probe but carried nothing.
  final int ruledOut;
  final bool usingFallback;

  /// Which protocol this search is sweeping for, when whatever started it knew.
  ///
  /// Field report, 2026-09-22: a healthy MASQUE search on an iPhone was stopped
  /// at 70 seconds because the screen read as hung. QA measured MASQUE at about
  /// two minutes against 30 to 60 seconds for the other two protocols, so that
  /// wait was normal, and the cancel landed 20 seconds before the automatic
  /// HTTP/2 fallback would have taken over. A card that can name the protocol
  /// can say which of those waits the person is in.
  ///
  /// Null when the caller does not know, and then the card keeps to what is
  /// true of every protocol rather than guessing.
  final AetherMode? mode;

  /// The same progress, tagged with the protocol the search is running on.
  AetherSearchProgress withMode(AetherMode mode) => AetherSearchProgress(
        attempt: attempt,
        verifying: verifying,
        ruledOut: ruledOut,
        usingFallback: usingFallback,
        mode: mode,
      );
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
    this.proofBudget = const Duration(seconds: 20),
  });

  /// How many gateways to try before giving up, passed to the finder.
  final int attempts;

  /// How often a running job is polled. Long enough not to spin the FFI
  /// boundary, short enough that Cancel feels immediate.
  final Duration pollEvery;

  /// How long one gateway gets to prove it carries traffic.
  ///
  /// Twenty seconds, against the core's own fixed five. Five is too few on a
  /// slow path: measured on 2026-09-16, a known-good gateway needs 3.0 to 3.5s
  /// at 600ms RTT with 5% loss and fails outright past that, which is a working
  /// address being reported as a dead one. A user waiting on a search would
  /// rather wait than be told, wrongly, that there is nothing out there.
  final Duration proofBudget;

  AetherCore? _core;
  int? _job;
  bool _cancelled = false;
  AetherIdentityRecovery _recovery = AetherIdentityRecovery();

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
    _recovery = AetherIdentityRecovery();
    _log(
        'start on ${AetherSearchLog.platform()}: ${AetherSearchLog.settings(options)}'
        '${excludedFirst.isEmpty ? '' : ', skipping ${excludedFirst.length}'}');
    final AetherCore core = AetherCore.open();
    _log(
        'engine ${AetherSearchLog.scrub(core.version())}, proof budget ${proofBudget.inSeconds}s');
    _core = core;

    // A path prefix, not a directory: the core appends the transport, so this
    // becomes aether-masque (and aether-masque-lastconn) beside it.
    final Directory dir = await getApplicationSupportDirectory();
    final Stopwatch idClock = Stopwatch()..start();
    final AetherJobStatus opened = await _await(
        core, core.identityOpen(options, base: '${dir.path}/aether'));
    if (opened.state != AetherJobState.done) {
      _log(
          'identity failed after ${idClock.elapsedMilliseconds}ms: '
          '${AetherSearchLog.scrub(opened.error)}',
          level: NovaLogLevel.error);
      return AetherFindResult(
          endpoint: null,
          error: opened.error ?? 'the WARP identity could not be opened',
          attempts: 0,
          rejected: const <String>[]);
    }
    _log('identity ready in ${idClock.elapsedMilliseconds}ms');
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
        final Stopwatch clock = Stopwatch()..start();
        final AetherJobStatus found =
            await _await(core, core.scanStart(identity, o, excluded: excluded));
        final String where =
            AetherEndpoint.parse(found.result?['endpoint']) ?? 'nothing';
        _log(
            'scan $attempt took ${clock.elapsedMilliseconds}ms, '
            'excluded ${excluded.length}: ${found.state.name}, $where'
            '${found.error == null ? '' : ', ${AetherSearchLog.scrub(found.error)}'}',
            level: found.state == AetherJobState.done
                ? NovaLogLevel.info
                : NovaLogLevel.warn);
        return found;
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
        return _proveWithRecovery(core, identity, o, endpoint, port, opened);
      },
    );
    // Seed what is already known dead, so a replacement search does not offer
    // the address that just failed back again.
    for (final String dead in excludedFirst) {
      if (dead.isNotEmpty && !finder.rejected.contains(dead)) {
        finder.rejected.add(dead);
      }
    }
    final AetherFindResult result = await finder.find(options);
    _log(
        result.ok
            ? 'found ${result.endpoint} on attempt ${result.attempts}'
            : 'gave up after ${result.attempts}: '
                '${AetherSearchLog.scrub(result.error)} '
                '(ruled out ${result.rejected.length})',
        level: result.ok ? NovaLogLevel.info : NovaLogLevel.error);
    return result;
  }

  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async {
    if (endpoint.trim().isEmpty) return false;
    // A previous search that the user stopped must not decide this. Without
    // this line, Stop on a search made every later Check report a perfectly
    // good address as unhealthy for the life of the screen.
    _cancelled = false;
    _recovery = AetherIdentityRecovery();
    _log(
        'checking ${endpoint.trim()} on ${AetherSearchLog.platform()}: ${AetherSearchLog.settings(options)}');
    final AetherCore core = AetherCore.open();
    _log(
        'engine ${AetherSearchLog.scrub(core.version())}, proof budget ${proofBudget.inSeconds}s');
    final Directory dir = await getApplicationSupportDirectory();
    final AetherJobStatus opened = await _await(
        core, core.identityOpen(options, base: '${dir.path}/aether'));
    if (opened.state != AetherJobState.done) {
      _log('identity failed: ${AetherSearchLog.scrub(opened.error)}',
          level: NovaLogLevel.error);
      return false;
    }
    final Object? handle = opened.result?[kAetherIdentityField];
    if (handle is! num) {
      _log('identity returned no handle', level: NovaLogLevel.error);
      return false;
    }

    final int port = await AetherTunnel.freeLoopbackPort();
    final AetherJobStatus proof = await _proveWithRecovery(
        core, handle.toInt(), options, endpoint.trim(), port, opened);
    // The same two-part answer the finder reads: the state says the check ran,
    // `reachable` says what it concluded. Only an explicit false is a refusal,
    // so a core that does not report the field is still trusted.
    return proof.state == AetherJobState.done &&
        proof.result?['reachable'] != false;
  }

  Future<AetherJobStatus> _proveWithRecovery(
      AetherCore core,
      int identity,
      AetherOptions options,
      String endpoint,
      int port,
      AetherJobStatus opened) async {
    final AetherJobStatus proof =
        await _prove(core, identity, options, endpoint, port);
    final Object? path = opened.result?['path'];
    if (options.mode != AetherMode.masque ||
        options.transport != AetherTransport.h2 ||
        path is! String ||
        path.isEmpty) {
      return proof;
    }
    return _recovery.recover(
      rejected: proof,
      original: File(path),
      cancelled: () => _cancelled,
      log: (String message) => _log(message),
      provision: (String base) async {
        final AetherJobStatus fresh =
            await _await(core, core.identityOpen(options, base: base));
        final int? handle = _handleOf(fresh.result);
        final Object? freshPath = fresh.result?['path'];
        if (fresh.state != AetherJobState.done ||
            handle == null ||
            freshPath is! String) {
          throw StateError('replacement identity was not provisioned');
        }
        return AetherRecoveryIdentity(handle, File(freshPath));
      },
      prove: (int handle) async => _prove(core, handle, options, endpoint,
          await AetherTunnel.freeLoopbackPort()),
    );
  }

  /// Proves one gateway carries traffic, on Nova's budget rather than the
  /// core's.
  ///
  /// This replaces `aether_verify_start`, which asks the same question with a
  /// fixed five second deadline and answers every failure identically. The
  /// payload is the same one a real connection uses, so what is proved here is
  /// what the user will get: a tunnel is brought up on a scratch port, one
  /// request is made through it, and the tunnel is torn down again.
  ///
  /// The answer keeps the core's shape (`reachable` in the result) so the
  /// finder above is unchanged, and gains the two fields the core never gave:
  /// what the far end saw, and how long it took.
  ///
  /// A scratch port, never the one a live tunnel serves on, so proving an
  /// address cannot collide with a connection the user is already using.
  Future<AetherJobStatus> _prove(AetherCore core, int identity, AetherOptions o,
      String endpoint, int port) async {
    final Stopwatch clock = Stopwatch()..start();
    int? job;
    try {
      _log('starting tunnel to $endpoint');
      final AetherReply started = core.tunnelStart(identity, o,
          endpoint: endpoint, socks: '127.0.0.1:$port');
      if (!started.ok) {
        return _proved(clock, endpoint, false,
            error: started.error ?? 'the tunnel would not start');
      }
      job = _asInt(started['job']);
      if (job == null) {
        // The tunnel is already up and serving, and there is no handle to stop
        // it with. Trying the next address would start another one just as
        // untrackable, so the search stops here instead of leaking one WARP
        // session per attempt.
        _cancelled = true;
        _log(
            'the core started a tunnel without a job id, so it cannot be '
            'stopped; abandoning the search',
            level: NovaLogLevel.error);
        return _proved(clock, endpoint, false,
            error: 'the core started no job for the tunnel');
      }
      // A tunnel job stays running for as long as the tunnel is up, so there is
      // nothing to wait for it to finish. What matters is that it has not
      // already given up, and that the port is answering.
      if (core.jobPoll(job).isFailed) {
        return _proved(clock, endpoint, false,
            error: core.jobPoll(job).error ?? 'the tunnel failed on startup');
      }
      if (!await _awaitPort(core, job, port, clock)) {
        return _proved(clock, endpoint, false,
            error: core.jobPoll(job).isFailed
                ? (core.jobPoll(job).error ?? 'the tunnel gave up')
                : 'the tunnel never started serving');
      }
      _log('tunnel SOCKS listener ready after ${clock.elapsedMilliseconds}ms');
      final AetherTrafficProof proof = await AetherTrafficCheck.through(port,
          budget: proofBudget - clock.elapsed,
          abort: () => _cancelled,
          onStage: (String stage) =>
              _log('proof +${clock.elapsedMilliseconds}ms: $stage'));
      final AetherJobStatus status = core.jobPoll(job);
      if (status.isFailed) {
        _log(
            'native tunnel failed during proof: ${AetherSearchLog.scrub(status.error)}',
            level: NovaLogLevel.warn);
      }

      // The exit address is only recorded when the traffic actually went
      // through WARP. When it did not, that field is not a Cloudflare exit at
      // all, it is the user's own address, and this line ends up in a log they
      // are invited to paste into a support thread. `warp` still says what
      // happened, which is what makes the failure diagnosable without naming
      // the person reporting it.
      return _proved(clock, endpoint, proof.viaWarp,
          warp: proof.warp,
          ip: proof.viaWarp ? proof.ip : null,
          error: proof.error);
    } catch (e) {
      return _proved(clock, endpoint, false, error: '$e');
    } finally {
      if (job != null) {
        try {
          core.jobCancel(job);
          while (core.jobPoll(job).isRunning) {
            await Future<void>.delayed(pollEvery);
          }
        } catch (_) {
          // A tunnel that has already gone is not a failure to stop.
        }
      }
    }
  }

  /// Records the outcome and shapes it the way the finder expects.
  AetherJobStatus _proved(Stopwatch clock, String endpoint, bool ok,
      {String? warp, String? ip, String? error}) {
    final Map<String, dynamic> result = AetherSearchLog.proof(
        viaWarp: ok, warp: warp, ip: ip, ms: clock.elapsedMilliseconds);
    _log(
        'verify $endpoint took ${clock.elapsedMilliseconds}ms: '
        '${AetherSearchLog.fields(result)}'
        '${error == null ? '' : ', ${AetherSearchLog.scrub(error)}'}',
        level: ok ? NovaLogLevel.info : NovaLogLevel.warn);
    return AetherJobStatus(AetherJobState.done,
        result: result, error: ok ? null : error);
  }

  /// Waits for the tunnel's SOCKS port to accept, within what is left of the
  /// budget. Pointing a request at a port nothing is listening on yet is how a
  /// good gateway gets blamed for a race.
  ///
  /// The job is watched alongside the port. A core that has already given up on
  /// an address will never open the port, and waiting out the full budget for
  /// it turns every dead gateway into a twenty second pause. The budget is
  /// there for a slow path, not for a settled answer.
  Future<bool> _awaitPort(
      AetherCore core, int job, int port, Stopwatch clock) async {
    while (clock.elapsed < proofBudget) {
      if (_cancelled) return false;
      if (core.jobPoll(job).isFailed) return false;
      try {
        final Socket s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 500));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    return false;
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
        if (_cancelled) core.jobCancel(job);
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

  /// One line per stage of a search, into the log the user can already export.
  ///
  /// The search is the only part of Nova that talks to the network before a
  /// tunnel exists, and it used to record nothing at all. That is why a report
  /// of "it says the address is not healthy" could not be answered with
  /// anything better than a guess: the core's own words for the refusal, and
  /// how long it took to produce them, were thrown away at the FFI boundary.
  static void _log(String message, {NovaLogLevel level = NovaLogLevel.info}) =>
      NovaLog.instance.write('aether search: $message', level: level);

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

/// Tries HTTP/2 with ClientHello fragmentation after a failed MASQUE search,
/// or cancels the first attempt after 90 seconds before starting the fallback.
/// Awaiting cancellation prevents the old scan from surviving the timeout.
class AetherAdaptiveSearch implements AetherGatewaySearch {
  AetherAdaptiveSearch({
    AetherGatewaySearch Function()? createSearch,
    this.fallbackAfter = const Duration(seconds: 90),
  }) : _createSearch = createSearch ?? AetherCoreSearch.new;

  final AetherGatewaySearch Function() _createSearch;
  final Duration fallbackAfter;
  AetherGatewaySearch? _active;
  bool _cancelled = false;
  int _generation = 0;
  @override
  bool get cancelled => _cancelled;
  @override
  bool get available => (_active ??= _createSearch()).available;
  @override
  void cancel() {
    _cancelled = true;
    _generation++;
    _active?.cancel();
  }

  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) {
    _active?.cancel();
    _generation++;
    _cancelled = false;
    return (_active = _createSearch()).verifyAddress(options, endpoint);
  }

  @override
  Future<AetherFindResult> run(
      AetherOptions options, ValueChanged<AetherSearchProgress> onProgress,
      {List<String> excludedFirst = const <String>[]}) async {
    _active?.cancel();
    _cancelled = false;
    final int generation = ++_generation;
    final bool eligible = options.mode == AetherMode.masque &&
        (options.transport != AetherTransport.h2 || !options.fragment);
    final AetherGatewaySearch first = _active = _createSearch();
    bool timedOut = false;
    final Timer? timer = eligible
        ? Timer(fallbackAfter, () {
            timedOut = true;
            first.cancel();
          })
        : null;
    late AetherFindResult result;
    try {
      result =
          await first.run(options, onProgress, excludedFirst: excludedFirst);
    } finally {
      timer?.cancel();
    }
    if (_cancelled || generation != _generation) {
      return AetherFindResult(
          endpoint: null,
          attempts: result.attempts,
          rejected: result.rejected,
          error: 'cancelled');
    }
    if (!eligible || (result.ok && !timedOut)) return result;
    final AetherOptions fallback =
        options.copyWith(transport: AetherTransport.h2, fragment: true);
    final AetherGatewaySearch second = _active = _createSearch();
    // The protocol is unchanged by the fallback, which swaps the transport
    // under it, so it rides through rather than being dropped here.
    void report(AetherSearchProgress p) => onProgress(AetherSearchProgress(
        attempt: p.attempt,
        verifying: p.verifying,
        ruledOut: p.ruledOut,
        usingFallback: true,
        mode: p.mode));
    report(
        const AetherSearchProgress(attempt: 1, verifying: false, ruledOut: 0));
    // A gateway rejected on QUIC may work over TCP. Do not carry those
    // exclusions into a different transport.
    final AetherFindResult found = await second.run(fallback, report);
    return AetherFindResult(
        endpoint:
            _cancelled || generation != _generation ? null : found.endpoint,
        attempts: result.attempts + found.attempts,
        rejected: found.rejected,
        error: found.error,
        options: found.ok && !_cancelled && generation == _generation
            ? fallback
            : null);
  }
}
