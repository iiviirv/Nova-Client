import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/proxy_profile.dart';
import 'singbox/proxy_node.dart';
import 'singbox/singbox_config.dart';

/// The local SOCKS/HTTP port proxy mode listens on unless the user moves it.
/// 2080 is the convention every client in this space uses, which is exactly why
/// it collides: someone running another proxy app already has it.
const int kDefaultLocalProxyPort = 2080;

/// High-level connection lifecycle states surfaced to the UI.
enum ProxyConnectionState { disconnected, connecting, connected, disconnecting, error }

extension ProxyConnectionStateX on ProxyConnectionState {
  bool get isBusy =>
      this == ProxyConnectionState.connecting || this == ProxyConnectionState.disconnecting;
  bool get isActive => this == ProxyConnectionState.connected;
}

/// A point-in-time traffic sample (bytes/second + cumulative bytes).
@immutable
class TrafficStats {
  const TrafficStats({
    this.uplinkBps = 0,
    this.downlinkBps = 0,
    this.uplinkTotal = 0,
    this.downlinkTotal = 0,
  });

  final double uplinkBps;
  final double downlinkBps;
  final int uplinkTotal;
  final int downlinkTotal;

  static const TrafficStats zero = TrafficStats();
}

/// Per-node latency the running core measured for the auto-select pool.
///
/// [delayMsByKey] maps [proxyNodeKey] to the round-trip the core's urltest saw
/// through that node (only nodes that answered are present; a delay of 0 from
/// the core means "failed/untested" and is dropped). [selectedKey] is the node
/// the auto-selector is currently routing through, so the list can mark which
/// server is actually carrying traffic.
/// How many working servers the free list stops at.
///
/// The published pool is a few hundred, and testing all of them takes a couple
/// of minutes for a list nobody scrolls to the end of. Thirty servers that
/// carry traffic is more than anyone picks from, and stopping there turns the
/// wait from minutes into seconds.
const int kFreeListTarget = 30;

class CoreNodeHealth {
  const CoreNodeHealth({
    required this.delayMsByKey,
    this.testedKeys = const <String>{},
    this.selectedKey,
  });

  static const CoreNodeHealth empty =
      CoreNodeHealth(delayMsByKey: <String, int>{});

  final Map<String, int> delayMsByKey;

  /// Every node the core's urltest actually measured this round, whether or not
  /// it answered. A key here with no [delayMsByKey] entry means the core tried
  /// the node through the tunnel and got no successful round-trip: it is a dead
  /// or unusable exit, not one that "can't be tested". The list uses this to say
  /// "no response" instead of the misleading "not testable".
  final Set<String> testedKeys;

  final String? selectedKey;

  bool get isEmpty =>
      delayMsByKey.isEmpty && testedKeys.isEmpty && selectedKey == null;

  /// The core's latency for [node], or null if the core has no live figure.
  int? delayFor(ProxyNode node) => delayMsByKey[proxyNodeKey(node)];

  /// The core measured [node] this round (it may still have failed, see
  /// [delayFor]). False for a node outside the auto-select pool.
  bool wasTested(ProxyNode node) => testedKeys.contains(proxyNodeKey(node));

  /// How many servers have answered so far. What the free-list search screen
  /// counts up, since "found 40 working servers" is the only number in a sweep
  /// that means anything to the person waiting for it.
  int get workingCount => delayMsByKey.length;

  /// How many servers carry a verdict either way, answered or not.
  int get testedCount => testedKeys.length;

  bool isSelected(ProxyNode node) =>
      selectedKey != null && proxyNodeKey(node) == selectedKey;
}

/// The boundary between Nova Client's UI and the underlying proxy core.
///
/// Nova Client is an optimised Karing-style client: the actual data path is a
/// modified **sing-box** core, bound natively per platform (Android VpnService,
/// the Network Extension on iOS/macOS, a TUN service on desktop). That native
/// binding is intentionally **out of scope** for this milestone — see
/// [SingboxProxyController] for the platform-channel contract it implements.
///
/// Keeping the UI behind this abstraction means screens are built and reviewed
/// against [MockProxyController] today and switch to the real core by swapping
/// a single instance, with no UI changes.
/// A user-facing event the controller wants the UI to announce. Kept as a code
/// so the app shell can render it in the current app language.
enum ProxyNotice {
  /// A manually pinned server was dead, so Nova failed over to the fastest
  /// working one.
  ///
  /// No longer fired: an explicit choice is never overridden silently. Kept so
  /// older persisted state and tests that name it still compile.
  failoverToWorkingServer,

  /// The server the user picked came up but is not passing traffic. Nova keeps
  /// the choice (it is the user's) and says so, instead of quietly connecting
  /// through a different server than the one shown as selected.
  pinnedExitNoTraffic,

  /// The pinned server is no longer in the subscription (panels rotate clean
  /// IPs), so this session had to auto-select. Announced rather than silent.
  pinnedExitGone,

  /// Every server in the subscription came up but carried nothing, so Nova
  /// turned on the SNI-block bypass for it and reconnected. Persisted; the
  /// user can turn it off in the node list.
  sniBypassOn,

  /// The tunnel is up but repeated probes (and one full rebuild) never got any
  /// traffic through: "connected but no internet". Fired once, when the
  /// controller stops trying, so the user learns what to do instead of staring
  /// at an eternal "Verifying connection".
  tunnelHasNoInternet,
}

abstract class ProxyController extends ChangeNotifier {
  ProxyConnectionState get state;
  TrafficStats get traffic;
  ProxyProfile? get activeProfile;

  /// Human-readable error from the last failed connection attempt, if any.
  String? get lastError;

  /// Transient, user-facing notices the controller wants surfaced (for example,
  /// an automatic failover to a working server). The app shell listens, maps the
  /// code to a localized string, shows a snackbar, then resets it to null. It is
  /// a code (not a string) so the message follows the app language. Kept separate
  /// from [lastError] so an informational message doesn't read as a failure.
  final ValueNotifier<ProxyNotice?> notice = ValueNotifier<ProxyNotice?>(null);

  /// Live per-node latency the running core measured for the auto-select pool,
  /// keyed by [proxyNodeKey]. This is the only honest health signal for the
  /// nodes the SNI-block bypass is for: a clean-IP fronted node cannot be probed
  /// from outside the tunnel (the bypass fragments the ClientHello in a way only
  /// the core can), so the server list shows "tested when you connect" for it.
  /// Once the tunnel is up, the core's own urltest has real numbers for every
  /// node in the pool, measured through the exact same bypass, and this surfaces
  /// them so the list can finally show which servers actually work and which one
  /// is carrying traffic. Empty when not connected or on a single-node profile.
  final ValueNotifier<CoreNodeHealth> coreHealth =
      ValueNotifier<CoreNodeHealth>(CoreNodeHealth.empty);

  /// Proxy mode (full-device tunnel off): the local SOCKS5/HTTP port apps
  /// should point at, or null when there is no such thing (TUN mode). The
  /// dashboard shows it so a user knows how to reach the proxy.
  int? get localProxyPort => null;

  /// True when the OS system proxy currently points at [localProxyPort].
  bool get systemProxyOn => false;

  /// Sets or clears the OS system proxy for [localProxyPort]. Returns whether
  /// it took effect (macOS asks for admin approval; a declined prompt is a
  /// false here, not a silent nothing).
  Future<bool> setSystemProxy(bool on) async => false;

  /// Whether this host can run a measuring core (see [measureNodes]). The node
  /// list shows the "test all through the core" button only when true.
  bool get canMeasureNodes => false;

  /// True while a [measureNodes] run is in flight; drives the button's spinner.
  final ValueNotifier<bool> measuring = ValueNotifier<bool>(false);

  /// Measures every node in [nodes] through a second, tunnel-less core (no
  /// TUN, no system proxy) and publishes the round-trips on [coreHealth], so
  /// nodes the outside probe can only call "not testable" (Reality, obfuscated
  /// Hysteria2, SS2022, a clean-IP VLESS behind an SNI block) get a real
  /// number and a dead one reads "no response". The same builder as the
  /// auto-select config is used, so a node measures exactly as it would run.
  /// Returns the message to show when nothing could be measured, else null.
  ///
  /// With [merge] the existing readings are kept and only the nodes in this run
  /// are updated, which is what re-testing a single row does; without it the
  /// whole board is cleared first, which is what the lightning button does.
  /// With [stopAfterWorking] the run ends as soon as that many servers have
  /// answered. The free list uses it: the pool is deliberately larger than
  /// anyone needs, so testing all of it spends minutes to produce a list nobody
  /// scrolls through.
  Future<String?> measureNodes(List<ProxyNode> nodes,
          {bool merge = false, int? stopAfterWorking}) async =>
      'Not supported on this device yet';

  /// Stops a run in flight, keeping every reading it already produced.
  ///
  /// A sweep over a few hundred servers takes a while, and on a bad connection
  /// each one waits out its own timeout, so the run can outlast the user's
  /// patience by minutes. Every implementation already polls [measuring] to
  /// decide whether to keep going, so clearing it is the whole cancel: the
  /// current dial finishes or times out, nothing new starts, and the results so
  /// far stand. Safe to call when nothing is running.
  Future<void> cancelMeasure() async {
    measuring.value = false;
  }

  /// True when the tunnel reports connected but the controller has exhausted
  /// its traffic probes and its one self-heal rebuild without a single request
  /// getting through. The dashboard uses this to swap the amber "Verifying
  /// connection" subtitle for an honest failure message rather than implying
  /// the check is still in progress. Implementations set it and must clear it
  /// on every fresh connect/disconnect and whenever a probe succeeds.
  bool exitUnreachable = false;

  /// Optional hook the app wires so the controller can persist a profile it had
  /// to mutate on its own, e.g. clearing a dead pinned exit during auto-failover
  /// so the Servers list stops showing the dead server as selected. Without this
  /// the change would live only in memory and the UI would look out of sync.
  Future<void> Function(ProxyProfile profile)? persistProfile;

  /// When the tunnel last became active, used by the dashboard's uptime timer.
  /// Maintained centrally by observing [state] on every notification so the
  /// per-platform implementations don't each have to track it.
  DateTime? _connectedSince;
  DateTime? get connectedSince => _connectedSince;

  @override
  void notifyListeners() {
    if (state.isActive) {
      _connectedSince ??= DateTime.now();
    } else {
      _connectedSince = null;
    }
    super.notifyListeners();
  }

  /// Supplies the current routing/DNS options at connect time. Set once at
  /// startup from the settings controller; the real (sing-box / desktop) hosts
  /// read it when building the config so the Routing and DNS screens actually
  /// take effect. Null falls back to the defaults.
  SingboxRouteOptions Function()? routeOptionsProvider;

  /// The options to build the next config with (defaults when unset).
  SingboxRouteOptions get routeOptions =>
      routeOptionsProvider?.call() ?? const SingboxRouteOptions();

  /// Supplies a subscription fetcher that routes through the Google relay when
  /// it is active, so subscription refresh keeps working even if the panel's own
  /// domain is blocked. Returns null when the relay is off (fetch directly).
  /// Set once at startup from the relay controller.
  Future<String> Function(Uri)? Function()? subFetcherProvider;

  /// The subscription fetcher to resolve the next profile with (relay or direct).
  Future<String> Function(Uri)? get subFetcher => subFetcherProvider?.call();

  /// A `HttpClient.findProxy`-style directive for reaching the exit through the
  /// tunnel, or null when no explicit proxying is needed.
  ///
  /// On Android/iOS the data path is a system-wide TUN, so the app's own
  /// `dart:io` requests are already captured and this stays null. On desktop the
  /// core is a local `mixed` inbound that the OS proxy points at, but Dart's
  /// `HttpClient` does not consult the OS proxy, so conn-info (ping/geo) would
  /// otherwise leak out the real interface and report the machine's own IP.
  /// Desktop returns `PROXY 127.0.0.1:<port>` while connected so those probes go
  /// through the exit like every other platform.
  String? get proxyUri => null;

  /// The panel's name for the node with this [proxyNodeKey], or null when the
  /// controller has no name for it (or is a mock). Lets the dashboard show
  /// "Connected via `name`" instead of a clean-IP node's Cloudflare address.
  String? exitName(String? key) => null;

  /// Selects the profile to connect with (does not connect).
  void selectProfile(ProxyProfile? profile);

  /// Re-reads the real tunnel state from the platform (call on app resume so a
  /// still-running tunnel isn't shown as off). Default is a no-op.
  Future<void> syncStatus() async {}

  /// Starts the tunnel for [activeProfile].
  Future<void> connect();

  /// Tears the tunnel down.
  Future<void> disconnect();

  Future<void> toggle() {
    return state.isActive ? disconnect() : connect();
  }

  /// Switches a *live* tunnel to the currently-selected profile/exit without the
  /// user having to toggle off and back on. Select the new profile (or pin a
  /// node) first, then call this: it tears the tunnel down, waits for it to
  /// actually reach `disconnected`, and reconnects through the new exit. If the
  /// tunnel isn't up, it does nothing (the next manual connect uses the new
  /// selection). The wait matters on iOS/macOS: a Network Extension's stop is
  /// asynchronous, and calling start again while it's still stopping is dropped,
  /// which is exactly why switching servers used to silently leave you
  /// disconnected until you tapped connect again.
  ///
  /// Overlapping calls are coalesced: a reconnect that arrives while one is in
  /// flight (the user taps through several servers, or toggles the SNI bypass
  /// twice) does not start a second stop/start interleaved with the first. It
  /// marks the in-flight one to go round once more when it finishes, and that
  /// extra round picks up whatever selection is current by then. Without this,
  /// two interleaved reconnects could each wait on the other's state changes,
  /// time out, and both call connect(), which is how "stuck on connecting
  /// after switching servers quickly" came about.
  Future<void> reconnect() async {
    if (_reconnecting) {
      _reconnectAgain = true;
      return;
    }
    _reconnecting = true;
    try {
      do {
        _reconnectAgain = false;
        await _reconnectOnce();
      } while (_reconnectAgain);
    } finally {
      _reconnecting = false;
    }
  }

  bool _reconnecting = false;
  bool _reconnectAgain = false;

  Future<void> _reconnectOnce() async {
    final bool wasActive =
        state.isActive || state == ProxyConnectionState.connecting;
    if (!wasActive) return;
    await disconnect();
    await _awaitState(
      (ProxyConnectionState s) =>
          s == ProxyConnectionState.disconnected ||
          s == ProxyConnectionState.error,
      timeout: const Duration(seconds: 8),
    );
    await connect();
  }

  /// Completes when [test] passes for the current [state], or after [timeout].
  /// Used by [reconnect] to sequence a stop before the next start.
  Future<void> _awaitState(
    bool Function(ProxyConnectionState) test, {
    required Duration timeout,
  }) async {
    if (test(state)) return;
    final Completer<void> done = Completer<void>();
    void listener() {
      if (test(state) && !done.isCompleted) done.complete();
    }

    addListener(listener);
    try {
      await done.future.timeout(timeout, onTimeout: () {});
    } finally {
      removeListener(listener);
    }
  }
}
