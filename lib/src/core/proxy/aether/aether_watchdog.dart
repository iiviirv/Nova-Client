import 'dart:async';

/// Watches a running Aether tunnel and brings it back when it dies.
///
/// Why this exists. The core can stop serving while the app still thinks it is
/// connected, and the way it was reported is worse than a plain disconnect: the
/// tunnel device stays up, so every packet on the machine is routed into a
/// tunnel that carries nothing and the whole device loses the internet. A
/// tester described turning Nova off and watching hours of notifications arrive
/// at once. Waking from sleep is the reliable way to reproduce it, because the
/// socket the core is holding belongs to a network that no longer exists.
///
/// Before this, nothing anywhere watched the core. `AetherTunnel.liveIsServing`
/// was consulted in exactly one place, after traffic had already failed, and
/// only to decide the wording of a log line.
///
/// The policy is kept apart from the timer that drives it so it can be tested
/// without waiting in real time: [check] is the whole thing, and the caller
/// decides how often to call it.
class AetherWatchdog {
  AetherWatchdog({
    required this.isServing,
    required this.restart,
    this.log,
    this.now = DateTime.now,
    this.firstBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(seconds: 60),
  });

  /// Whether the tunnel is still doing its job. Answering false is what starts
  /// a restart, so this should be a real check of the core and its port rather
  /// than a flag the app set when it connected.
  final Future<bool> Function() isServing;

  /// Brings the tunnel back up on the same gateway and port.
  final Future<void> Function() restart;

  /// Somewhere to say what happened, so a user who watched their connection
  /// come back has a record of why.
  final void Function(String message, {bool warn})? log;

  /// Injectable so backoff can be tested without waiting for it.
  final DateTime Function() now;

  /// How long to wait before the first retry, and the ceiling it doubles to.
  ///
  /// Backoff matters here because the common cause is a network that is not
  /// there yet. A device waking from sleep has no route for a moment, so
  /// retrying as fast as possible would burn attempts on a failure that fixes
  /// itself, and each attempt opens an identity and dials a gateway.
  final Duration firstBackoff;
  final Duration maxBackoff;

  bool _busy = false;
  DateTime? _notBefore;
  Duration _backoff = Duration.zero;
  int _consecutive = 0;

  /// How many restarts in a row have been attempted without the tunnel coming
  /// back healthy. Exposed for the UI, which should stop claiming a healthy
  /// connection once this climbs.
  int get consecutiveFailures => _consecutive;

  /// True while a restart is in flight.
  bool get busy => _busy;

  /// One pass. Safe to call on a timer; overlapping calls do nothing.
  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      bool alive;
      try {
        alive = await isServing();
      } catch (_) {
        // A check that throws is a check that failed. Treating it as healthy is
        // how a dead tunnel stays up.
        alive = false;
      }
      if (alive) {
        if (_consecutive > 0) {
          log?.call('The Aether tunnel is carrying traffic again.');
        }
        _consecutive = 0;
        _backoff = Duration.zero;
        _notBefore = null;
        return;
      }

      final DateTime t = now();
      final DateTime? gate = _notBefore;
      if (gate != null && t.isBefore(gate)) return;

      _consecutive += 1;
      log?.call(
          'The Aether tunnel stopped carrying traffic, so nothing on this '
          'device could reach the internet. Restarting it (attempt '
          '$_consecutive).',
          warn: true);
      try {
        await restart();
      } catch (e) {
        log?.call('Could not restart the Aether tunnel: $e', warn: true);
      }
      // The gate is set after the attempt, not before it, so a restart that
      // takes ten seconds does not also get to skip the wait.
      _backoff = _backoff == Duration.zero
          ? firstBackoff
          : Duration(
              milliseconds:
                  (_backoff.inMilliseconds * 2).clamp(0, maxBackoff.inMilliseconds));
      _notBefore = now().add(_backoff);
    } finally {
      _busy = false;
    }
  }

  /// Forgets the backoff, so the next [check] acts immediately.
  ///
  /// Called when something happened that makes a stale wait pointless: the app
  /// came back to the foreground, or the network changed. Waiting out a
  /// sixty second backoff after the user has already unlocked their phone and
  /// is looking at a dead connection is the wrong behaviour.
  void wake() {
    _notBefore = null;
    _backoff = Duration.zero;
  }
}
