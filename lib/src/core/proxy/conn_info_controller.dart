import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'proxy_controller.dart';
import '../geo/node_geo_store.dart';

/// Live connection info shown on the dashboard metrics block: the public exit
/// IP, the country it geolocates to, and a round-trip ping. Mirrors the native
/// Android `NovaConnInfo`, which polls roughly every 6 seconds while connected.
@immutable
class ConnInfo {
  const ConnInfo({
    this.reachable = false,
    this.ip,
    this.countryCode,
    this.countryName,
    this.pingMs,
  });

  /// Whether a tiny request actually completes through the tunnel. This is the
  /// honest "is traffic getting through" signal, kept separate from [hasGeo]
  /// because geo providers rate-limit a shared exit IP and a failed lookup must
  /// never be read as a dead tunnel.
  final bool reachable;
  final String? ip;
  final String? countryCode; // ISO-2, e.g. "DE"
  final String? countryName;
  final int? pingMs;

  bool get hasGeo => (countryCode?.isNotEmpty ?? false);

  static const ConnInfo empty = ConnInfo();
}

/// Polls the exit IP/country/ping while the proxy is connected and clears it
/// when disconnected. Best-effort: any network failure leaves the last good
/// value (or empty) and never throws into the UI.
class ConnInfoController extends ChangeNotifier {
  ConnInfoController(this._proxy) {
    _proxy.addListener(_onProxyChanged);
    _proxy.coreHealth.addListener(_onCoreHealth);
    _client = _makeClient();
    // Pause the 6-second exit-IP poll while the app is backgrounded. The reading
    // only feeds the dashboard, which nobody is looking at when we are not in the
    // foreground, so probing the network on a timer there is pure battery and
    // data waste over a long-running tunnel. We resume (and refresh at once) when
    // the user comes back.
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  AppLifecycleListener? _lifecycle;
  bool _foreground = true;

  void _onLifecycle(AppLifecycleState state) {
    final bool fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    if (!_wasActive) return;
    if (fg) {
      // Back in view: refresh straight away so a stale reading does not linger,
      // then resume the periodic poll.
      _refresh();
      _armPoll();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// (Re)arms the periodic poll, but only while the app is in the foreground.
  void _armPoll() {
    _timer?.cancel();
    if (!_foreground) return;
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
  }

  /// A fresh client whose connections are made *after* the tunnel is up. We
  /// rebuild it on each connect so the probe never reuses a keep-alive socket
  /// opened before the tunnel existed — that stale socket is exactly why the
  /// country/ping used to stay blank until a reconnect.
  HttpClient _makeClient() {
    final HttpClient c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..idleTimeout = const Duration(seconds: 3);
    // On desktop the proxy is a local inbound that dart:io won't use on its own,
    // so route these probes through it. On TUN platforms proxyUri is null and
    // this resolves to DIRECT (already tunneled).
    c.findProxy = (_) => _proxy.proxyUri ?? 'DIRECT';
    return c;
  }

  final ProxyController _proxy;

  ConnInfo _info = ConnInfo.empty;
  ConnInfo get info => _info;

  bool _loading = false;
  bool get loading => _loading;

  Timer? _timer;
  bool _wasActive = false;
  late HttpClient _client;

  /// Bumped on every connect and disconnect. A geo lookup carries the id it was
  /// started under, so an answer that arrives after the tunnel dropped is
  /// discarded instead of being written onto a node as its exit country. That
  /// is what used to stamp a server with the user's OWN country: the request
  /// went out through the tunnel, the tunnel went away, and the retry landed on
  /// the real network.
  int _session = 0;

  /// The core just proved a node actually carries traffic (a real urltest delay
  /// on the selected exit). That means the tunnel is routing NOW, so probe
  /// immediately rather than waiting for the next warmup tick, which is what
  /// makes the hero flip to "Secure" seconds sooner instead of sitting on the
  /// amber "Verifying".
  /// The running core's own latency for the exit that is carrying traffic.
  ///
  /// This is the honest "ping" to show while connected: sing-box measures it
  /// with a plain-http request that is already inside the tunnel, so it is one
  /// round trip. The controller's own reachability probe has to use https (a
  /// captive portal can fake a plain-http 204, and that verdict must not be
  /// faked), which costs a second TLS handshake through the proxy and roughly
  /// doubles the figure. Showing that doubled number made a perfectly good
  /// connection look slow.
  int? _coreDelay() {
    final CoreNodeHealth h = _proxy.coreHealth.value;
    final String? sel = h.selectedKey ?? _proxy.activeProfile?.pinnedNode;
    if (sel == null) return null;
    return h.delayMsByKey[sel];
  }

  void _onCoreHealth() {
    // A fresher core figure is a fresher ping, even once the verdict is in.
    if (_wasActive && _info.reachable) {
      final int? live = _coreDelay();
      if (live != null && live != _info.pingMs) {
        _info = ConnInfo(
          reachable: _info.reachable,
          ip: _info.ip,
          countryCode: _info.countryCode,
          countryName: _info.countryName,
          pingMs: live,
        );
        notifyListeners();
      }
    }
    if (!_wasActive || _info.reachable) return;
    final CoreNodeHealth h = _proxy.coreHealth.value;
    final String? sel = h.selectedKey;
    final int? delay = sel == null ? null : h.delayMsByKey[sel];
    if (delay == null) return;
    // The core measured real traffic through the selected exit: that IS
    // reachability, and it is more reliable than the external 204 probe, which a
    // flaky endpoint can stall on and leave the hero stuck on "Verifying". Flip
    // to reachable now (with the core's ping) so "Secure" shows, then fill in the
    // IP/country in the background without gating the verdict on it.
    _loading = false;
    _info = ConnInfo(
      reachable: true,
      ip: _info.ip,
      countryCode: _info.countryCode,
      countryName: _info.countryName,
      pingMs: _info.pingMs ?? delay,
    );
    notifyListeners();
    unawaited(_fillGeoInBackground());
  }

  /// Fetches the exit IP/country after [reachable] is already true, so the geo
  /// fills in without holding up the "Secure" verdict. Best-effort.
  Future<void> _fillGeoInBackground() async {
    final int session = _session;
    try {
      final ConnInfo? geo = await _fetchGeo();
      if (!_wasActive || session != _session || geo == null) return;
      _info = ConnInfo(
        reachable: _info.reachable,
        ip: geo.ip ?? _info.ip,
        countryCode: geo.countryCode ?? _info.countryCode,
        countryName: geo.countryName ?? _info.countryName,
        pingMs: _coreDelay() ?? _info.pingMs ?? geo.pingMs,
      );
      notifyListeners();
      _rememberExitCountry(geo, session);
    } catch (_) {
      // Geo is optional; "Secure" already stands on the core's proof.
    }
  }

  void _onProxyChanged() {
    final bool active = _proxy.state.isActive;
    if (active && !_wasActive) {
      _start();
    } else if (!active && _wasActive) {
      _stop();
    }
    _wasActive = active;
  }

  void _start() {
    _session++;
    _info = ConnInfo.empty;
    _loading = true;
    notifyListeners();
    // Fresh client so probes use sockets opened through the new tunnel.
    _client.close(force: true);
    _client = _makeClient();
    // The tunnel needs a moment to actually route (urltest picks a node, DNS
    // warms up). Probe right away, then a few quick retries until it's reachable
    // — without this the first reading stayed blank until a manual reconnect.
    _refresh();
    _scheduleWarmup();
    _armPoll();
  }

  void _scheduleWarmup() {
    // Front-loaded so "Secure" flips as soon as the tunnel routes, which with the
    // forced urltest is usually within a second or two. The [_onCoreHealth] hook
    // fires the instant the core proves a node, so these are just the fallback.
    const List<int> delays = <int>[700, 1400, 2500, 4000, 6500];
    for (final int ms in delays) {
      Timer(Duration(milliseconds: ms), () {
        if (_wasActive && !_info.reachable) _refresh();
      });
    }
  }

  void _stop() {
    _session++;
    _timer?.cancel();
    _timer = null;
    _loading = false;
    _info = ConnInfo.empty;
    notifyListeners();
  }

  /// The exit country just observed belongs to the node carrying traffic: the
  /// pinned one, or the auto-selector's current pick. Remember it against the
  /// node so its flag is right from now on (and is never re-guessed from the
  /// address, which for a CDN-fronted node is not even where traffic exits).
  void _rememberExitCountry(ConnInfo geo, int session) {
    // Only ever while the tunnel this reading came from is still the live one.
    if (session != _session || !_proxy.state.isActive) return;
    final String? cc = geo.countryCode;
    if (cc == null || cc.isEmpty) return;
    final String? key = _proxy.coreHealth.value.selectedKey ??
        _proxy.activeProfile?.pinnedNode;
    if (key == null || key.isEmpty) return;
    NodeGeoStore.instance.learnExit(key, cc, countryName: geo.countryName);
  }

  Future<void> _refresh() async {
    final int session = _session;
    final (bool reachable, int? probePing) = await _probe();
    final ConnInfo? geo = reachable ? await _fetchGeo() : null;
    // The tunnel came down while this round was in flight: everything it
    // measured is about the real network now, not the exit, so drop it.
    if (session != _session) return;
    _loading = false;
    // Prefer the dedicated probe's round-trip; otherwise fall back to the geo
    // request's round-trip so the ping never reads blank while a country is
    // clearly resolving. A provider that rate-limits the probe endpoint but
    // serves geo would otherwise leave PING empty for the whole session.
    final int? ping = _coreDelay() ?? probePing ?? geo?.pingMs ?? _info.pingMs;
    _info = ConnInfo(
      reachable: reachable,
      ip: geo?.ip ?? _info.ip,
      countryCode: geo?.countryCode ?? _info.countryCode,
      countryName: geo?.countryName ?? _info.countryName,
      pingMs: ping,
    );
    notifyListeners();
    if (geo != null) _rememberExitCountry(geo, session);
  }

  /// A tiny `generate_204` request through the tunnel: its completion is the
  /// reachability signal, and its round-trip doubles as a coarse ping. Tries a
  /// couple of non-Cloudflare 204 endpoints in turn (a Nova worker can't relay
  /// to Cloudflare's own endpoints without hitting loop protection, which is
  /// why pinging 1.1.1.1 used to always fail) so one blocked host doesn't drop
  /// the reading entirely.
  Future<(bool, int?)> _probe() async {
    const List<String> urls = <String>[
      'https://www.gstatic.com/generate_204',
      'https://connectivitycheck.gstatic.com/generate_204',
      'https://www.google.com/generate_204',
    ];
    for (final String url in urls) {
      try {
        final Stopwatch sw = Stopwatch()..start();
        final HttpClientRequest req = await _client.getUrl(Uri.parse(url));
        req.followRedirects = false;
        // Hard timeouts on the response: a flaky exit can connect and then
        // never answer, and without these the probe hangs forever, so the hero
        // stays on "Verifying" indefinitely (the exact stuck state users hit).
        // Failing fast lets the next warmup/periodic probe get through.
        final HttpClientResponse res =
            await req.close().timeout(const Duration(seconds: 5));
        await res.drain<void>().timeout(const Duration(seconds: 5));
        sw.stop();
        final bool ok = res.statusCode >= 200 && res.statusCode < 400;
        if (ok) return (true, sw.elapsedMilliseconds);
      } catch (_) {
        // Try the next endpoint.
      }
    }
    return (false, null);
  }

  /// Best-effort exit IP + country over HTTPS, trying providers in turn. The
  /// **non-Cloudflare** provider comes first on purpose: a Nova exit is a
  /// Cloudflare Worker, and a Worker can't relay to Cloudflare's own hosts (loop
  /// protection), so any CF-fronted geo API just fails through the tunnel and the
  /// country stayed blank. Most geo APIs now sit behind Cloudflare (ifconfig.co,
  /// freeipapi, ipwho.is, api.ip.sb, ipapi.co ... all resolve to 104.x/172.6x);
  /// ipinfo.io is the reliable off-Cloudflare one (Google Cloud), so it leads.
  /// The CF ones stay as fallbacks for non-worker exits. The successful request's
  /// round-trip back-fills a coarse ping. Field names differ per provider, so the
  /// parse is tolerant. (ip-api is skipped: cleartext, blocked on a modern SDK.)
  Future<ConnInfo?> _fetchGeo() async {
    const List<String> urls = <String>[
      'https://ipinfo.io/json',
      'https://ifconfig.co/json',
      'https://freeipapi.com/api/json',
      'https://ipwho.is/',
      'https://api.ip.sb/geoip',
    ];
    for (final String url in urls) {
      try {
        final Stopwatch sw = Stopwatch()..start();
        final HttpClientRequest req = await _client.getUrl(Uri.parse(url));
        final HttpClientResponse res = await req.close();
        if (res.statusCode != 200) {
          await res.drain<void>();
          continue;
        }
        final String body = await res.transform(utf8.decoder).join();
        sw.stop();
        final Map<String, dynamic> j = jsonDecode(body) as Map<String, dynamic>;
        final ConnInfo? parsed = _parseGeo(j, sw.elapsedMilliseconds);
        if (parsed != null) return parsed;
      } catch (_) {
        // Try the next provider.
      }
    }
    return null;
  }

  /// Extracts ip / ISO country code / country name from any of the supported
  /// providers, whose JSON keys differ:
  ///   ifconfig.co → ip, country_iso, country
  ///   ipinfo.io   → ip, country (already the ISO code)
  ///   freeipapi   → ipAddress, countryCode, countryName
  ///   ipwho.is / api.ip.sb → ip, country_code, country
  ConnInfo? _parseGeo(Map<String, dynamic> j, int pingMs) {
    final String? ip = (j['ip'] ?? j['ipAddress']) as String?;
    if (ip == null || ip.isEmpty) return null;
    final String? country = j['country'] is String ? j['country'] as String : null;
    // Prefer an explicit ISO field; otherwise a 2-letter "country" is the code.
    String? cc = (j['country_code'] ??
            j['country_iso'] ??
            j['countryCode']) as String?;
    if ((cc == null || cc.isEmpty) && country != null && country.length == 2) {
      cc = country;
    }
    // A full country name, when the provider gives one distinct from the code.
    final String? name = (j['country_name'] ?? j['countryName']) as String? ??
        (country != null && country.length > 2 ? country : null);
    return ConnInfo(
      ip: ip,
      countryCode: cc?.toUpperCase(),
      countryName: name,
      pingMs: pingMs,
    );
  }

  @override
  void dispose() {
    _proxy.removeListener(_onProxyChanged);
    _proxy.coreHealth.removeListener(_onCoreHealth);
    _lifecycle?.dispose();
    _timer?.cancel();
    _client.close(force: true);
    super.dispose();
  }
}

/// Turns an ISO-3166 alpha-2 code into its flag emoji (regional indicators).
String? countryFlagEmoji(String? iso2) {
  final String? code = iso2?.toUpperCase();
  if (code == null || code.length != 2) return null;
  final int a = code.codeUnitAt(0);
  final int b = code.codeUnitAt(1);
  if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return null;
  return String.fromCharCode(0x1F1E6 + (a - 0x41)) +
      String.fromCharCode(0x1F1E6 + (b - 0x41));
}
