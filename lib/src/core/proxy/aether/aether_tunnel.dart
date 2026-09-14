import 'dart:async';
import 'dart:io';

import 'aether_core.dart';
import 'aether_options.dart';
import 'aether_protocol.dart';

/// A running Aether tunnel: the thing sing-box forwards into.
///
/// Aether is not handed to the platform layer the way the Xray config is. It is
/// a library this process drives, so something has to own the live tunnel: the
/// identity handle, the job, and the local port it serves on. That is this.
///
/// Starting is two steps that are easy to collapse and should not be. Opening
/// the identity talks to Cloudflare on a first run and can take seconds; only
/// once it succeeds is there a handle to start a tunnel with. Treating either
/// as instant produces a tunnel that is not up when sing-box starts forwarding
/// into it, which shows as a connection that comes up and carries nothing.
class AetherTunnel {
  AetherTunnel._(this._core, this.identity, this.job, this.socksPort);

  final AetherCore _core;

  /// The open identity's handle.
  final int identity;

  /// The running tunnel's job id, used to stop it.
  final int job;

  /// The loopback port the tunnel serves SOCKS5 on.
  final int socksPort;

  static AetherTunnel? _live;

  /// The tunnel currently running, if any.
  static AetherTunnel? get live => _live;

  /// Brings a tunnel up and waits until it is actually serving.
  ///
  /// [endpoint] is the gateway to dial. A config that has never been searched
  /// has none, and that is a real state rather than an error: the caller should
  /// run a search first, because starting a tunnel with no address would ask
  /// the core to scan while the user waits on a connect button with no progress
  /// to look at.
  static Future<AetherTunnel> start(
    AetherOptions options, {
    required String endpoint,
    required String identityBase,
    int? port,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    await stop();
    final AetherCore core = AetherCore.open();

    final AetherJobStatus opened = await _run(
        core, core.identityOpen(options, base: identityBase), timeout);
    if (opened.state != AetherJobState.done) {
      throw AetherUnavailable(
          opened.error ?? 'the WARP identity could not be opened');
    }
    final Object? handle = opened.result?[kAetherIdentityField];
    if (handle is! num) {
      throw AetherUnavailable('the core returned no identity handle');
    }
    final int id = handle.toInt();

    final int socks = port ?? await freeLoopbackPort();
    final AetherReply started = core.tunnelStart(id, options,
        endpoint: endpoint, socks: '127.0.0.1:$socks');
    if (!started.ok) {
      throw AetherUnavailable(started.error ?? 'the tunnel would not start');
    }
    final Object? jobId = started['job'];
    if (jobId is! num) {
      throw AetherUnavailable('the core started no job for the tunnel');
    }

    // A tunnel job stays running for as long as the tunnel is up, so unlike a
    // scan there is nothing to wait for it to finish. What matters is that it
    // has not already failed, and that the port is answering before anything is
    // pointed at it.
    final AetherJobStatus now = core.jobPoll(jobId.toInt());
    if (now.state == AetherJobState.failed) {
      throw AetherUnavailable(now.error ?? 'the tunnel failed on startup');
    }
    await _awaitPort(socks, timeout);

    return _live = AetherTunnel._(core, id, jobId.toInt(), socks);
  }

  /// Stops the running tunnel, if there is one. Safe to call when there is not.
  static Future<void> stop() async {
    final AetherTunnel? t = _live;
    _live = null;
    if (t == null) return;
    try {
      t._core.jobCancel(t.job);
    } catch (_) {
      // A core that has already gone is not a failure to stop.
    }
  }

  /// Polls a job until it finishes or the deadline passes.
  static Future<AetherJobStatus> _run(
      AetherCore core, AetherReply started, Duration timeout) async {
    if (!started.ok) {
      return AetherJobStatus(AetherJobState.failed, error: started.error);
    }
    final Object? job = started['job'];
    if (job is! num) {
      return const AetherJobStatus(AetherJobState.failed,
          error: 'the core started no job');
    }
    final DateTime deadline = DateTime.now().add(timeout);
    AetherJobStatus st = core.jobPoll(job.toInt());
    while (st.isRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      st = core.jobPoll(job.toInt());
    }
    if (st.isRunning) {
      core.jobCancel(job.toInt());
      return const AetherJobStatus(AetherJobState.failed,
          error: 'the core did not answer in time');
    }
    return st;
  }

  /// Waits for the SOCKS port to accept a connection.
  ///
  /// Without this, sing-box is pointed at a port nothing is listening on yet
  /// and the first connections fail for no reason the user can see. The desktop
  /// controller learned the same lesson waiting on a port rather than sleeping
  /// a fixed number of milliseconds.
  static Future<void> _awaitPort(int port, Duration timeout) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final Socket s = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 500));
        s.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw AetherUnavailable('the tunnel never started serving on $port');
  }

  /// A free loopback port, asked of the OS rather than picked from a range, so
  /// two tunnels or a tunnel and a probe cannot land on the same one.
  static Future<int> freeLoopbackPort() async {
    final ServerSocket s =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int p = s.port;
    await s.close();
    return p;
  }
}
