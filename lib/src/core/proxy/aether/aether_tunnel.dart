import 'dart:async';
import 'dart:io';

import '../../logging/nova_log.dart';
import 'aether_core.dart';
import 'aether_options.dart';
import 'aether_protocol.dart';
import 'aether_startup.dart';
import 'aether_watchdog.dart';

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

  /// What the live tunnel was started with, kept so it can be brought back
  /// without asking the caller to remember anything.
  static _Spec? _spec;
  static AetherWatchdog? _dog;
  static Timer? _dogTimer;

  /// How often the live tunnel is checked.
  ///
  /// Fifteen seconds is a compromise. The failure being watched for takes the
  /// whole device offline, so noticing it late is expensive; but each check
  /// opens a loopback connection, and doing that every second for the life of a
  /// connection is not free either.
  static const Duration watchEvery = Duration(seconds: 15);

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
    final AetherTunnel t = await _open(options,
        endpoint: endpoint,
        identityBase: identityBase,
        port: port,
        timeout: timeout);
    _spec = _Spec(options, endpoint, identityBase, t.socksPort, timeout);
    _arm();
    return t;
  }

  /// Starts the watchdog for the live tunnel.
  ///
  /// The core can stop serving while the app still believes it is connected,
  /// and the way that showed up was worse than a disconnect: the tunnel device
  /// stayed up, so every packet was routed into a tunnel carrying nothing and
  /// the device lost the internet entirely until Nova was switched off. Waking
  /// from sleep reproduces it, because the socket the core holds belongs to a
  /// network that is no longer there.
  static void _arm() {
    _dogTimer?.cancel();
    _dog = AetherWatchdog(
      isServing: _probe,
      restart: _restart,
      log: (String m, {bool warn = false}) => NovaLog.instance.write(m,
          level: warn ? NovaLogLevel.warn : NovaLogLevel.info),
    );
    _dogTimer = Timer.periodic(watchEvery, (_) => _dog?.check());
  }

  /// Checks the thing that actually matters, which is not the flag the app set
  /// when it connected.
  ///
  /// Two questions, because they fail separately: the core can report its job
  /// as failed, and it can also quietly stop accepting on the port sing-box
  /// forwards into while the job still looks alive.
  static Future<bool> _probe() async {
    final AetherTunnel? t = _live;
    if (t == null) return true; // nothing to watch
    if (liveIsServing == false) return false;
    try {
      final Socket s = await Socket.connect('127.0.0.1', t.socksPort,
          timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _restart() async {
    final _Spec? spec = _spec;
    if (spec == null) return;
    final AetherTunnel? old = _live;
    _live = null;
    if (old != null) {
      try {
        old._core.jobCancel(old.job);
      } catch (_) {
        // Already gone, which is the case being recovered from.
      }
    }
    // The same port on purpose: sing-box is already forwarding into it and has
    // no idea any of this happened.
    await _open(spec.options,
        endpoint: spec.endpoint,
        identityBase: spec.identityBase,
        port: spec.port,
        timeout: spec.timeout);
  }

  /// Tells the watchdog to stop waiting out a backoff. Called when the app
  /// comes back to the foreground or the network changes, because those are
  /// exactly the moments a stale wait is pointless and the user is looking at
  /// a dead connection.
  static void wake() {
    _dog?.wake();
    unawaited(_dog?.check());
  }

  static Future<AetherTunnel> _open(
    AetherOptions options, {
    required String endpoint,
    required String identityBase,
    int? port,
    required Duration timeout,
  }) async {
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
    await waitForAetherStartup(
      poll: () => core.jobPoll(jobId.toInt()),
      cancel: () => core.jobCancel(jobId.toInt()),
      timeout: timeout,
      accepts: () async {
        try {
          final socket = await Socket.connect('127.0.0.1', socks,
              timeout: const Duration(milliseconds: 500));
          socket.destroy();
          return true;
        } catch (_) {
          return false;
        }
      },
    );

    return _live = AetherTunnel._(core, id, jobId.toInt(), socks);
  }

  /// Whether the live tunnel is still doing its job.
  ///
  /// Worth asking before blaming the gateway. The core can give up after it has
  /// started, and when it does it closes the port sing-box forwards into, so
  /// every request fails at the bridge and none of it is Cloudflare's doing.
  /// Null when there is no tunnel to ask about.
  static bool? get liveIsServing {
    final AetherTunnel? t = _live;
    if (t == null) return null;
    try {
      return !t._core.jobPoll(t.job).isFailed;
    } catch (_) {
      return false;
    }
  }

  /// Stops the running tunnel, if there is one. Safe to call when there is not.
  static Future<void> stop() async {
    _dogTimer?.cancel();
    _dogTimer = null;
    _dog = null;
    _spec = null;
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


/// What a tunnel was started with, so it can be started again unchanged.
class _Spec {
  const _Spec(
      this.options, this.endpoint, this.identityBase, this.port, this.timeout);

  final AetherOptions options;
  final String endpoint;
  final String identityBase;
  final int port;
  final Duration timeout;
}
