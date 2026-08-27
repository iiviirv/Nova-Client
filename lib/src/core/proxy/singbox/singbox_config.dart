import 'dart:convert';

import 'awg_config.dart';
import 'proxy_node.dart';

/// Routing behaviour, mapping onto the controls on the Routing screen.
enum SingboxMode { rule, global, direct }

/// Defaults for the URL-test settings. Plain http on purpose: the test rides
/// inside the encrypted tunnel and an https target adds a second TLS
/// handshake to every measurement.
const String kDefaultUrlTestUrl = 'http://www.gstatic.com/generate_204';
const int kDefaultUrlTestTimeoutSec = 5;
const int kDefaultUrlTestIntervalSec = 180;
const int kDefaultUrlTestToleranceMs = 50;

class SingboxRouteOptions {
  const SingboxRouteOptions({
    this.mode = SingboxMode.rule,
    this.blockAds = true,
    this.bypassIran = true,
    this.bypassLan = true,
    this.dns = '',
    this.lean = false,
    this.localRuleSets = false,
    this.urlTestUrl = kDefaultUrlTestUrl,
    this.urlTestTimeoutSec = kDefaultUrlTestTimeoutSec,
    this.urlTestIntervalSec = kDefaultUrlTestIntervalSec,
    this.urlTestToleranceMs = kDefaultUrlTestToleranceMs,
    this.tlsFragment = true,
    this.gvisorStack = false,
    this.hy2UpMbps = 0,
    this.hy2DownMbps = 0,
    this.fingerprintOverride,
    this.autoOptimizeCarrier = false,
    this.verboseCoreLog = false,
    this.hardenTls = false,
    this.hardenPacketFragment = true,
    this.bypassFingerprint,
    this.bypassCipherSuites,
    this.bypassFragmentMask,
    this.tunInterfaceName,
    this.mixedInboundPort,
    this.includePackages = const <String>[],
    this.excludePackages = const <String>[],
    this.tunWithLocalProxy = false,
  });

  /// Proxy mode: listen on this loopback port with a `mixed` (SOCKS5 + HTTP)
  /// inbound and build NO TUN, so the device's traffic is untouched and only an
  /// app pointed at the port goes through Nova.
  ///
  /// On a phone there is no system-proxy setting to flip, so this is for the
  /// apps that have their own proxy field (a browser, a messenger, a dev tool).
  /// It also means no VPN slot is taken: another VPN can be running at the same
  /// time, which a full-device tunnel makes impossible.
  final int? mixedInboundPort;

  /// The name to give the TUN interface, or null to let the core choose.
  ///
  /// macOS only accepts `utun<N>` here: anything else fails the connect with
  /// "configure tun interface: bad tun name", which is what a hardcoded
  /// "nova-tun" did to every Mac in full-device mode. Windows (wintun) and
  /// Linux take an arbitrary name, so the desktop controller passes one there
  /// and leaves this null on macOS. Ignored on Android and iOS, where the
  /// platform owns the interface.
  final String? tunInterfaceName;

  /// Per-profile SNI-block bypass overrides from the editor, each null to use
  /// Nova's field-tested default (`unsafe` / [kBypassCipherSuites] /
  /// [kBypassFragmentMask]). Only consulted when [hardenTls] is on.
  final String? bypassFingerprint;
  final List<String>? bypassCipherSuites;
  final String? bypassFragmentMask;

  final SingboxMode mode;
  final bool blockAds;
  final bool bypassIran;
  final bool bypassLan;

  /// Use the bundled LOCAL rule-set files instead of downloading them at
  /// startup. sing-box FATALs when a remote rule-set can't be fetched, and the
  /// CDN it pulls from (raw.githubusercontent.com) is filtered in Iran, so the
  /// desktop core died with "the core did not come up in time". Desktop ships
  /// the .srs files and points at them on disk. Only geosite-ir / geosite-ads
  /// are bundled, so geoip-ir bypass is skipped in this mode (the geosite-ir
  /// domain list still covers Iranian sites). The lean/iOS path already uses
  /// local rule-sets by its own branch; this brings the full path in line.
  final bool localRuleSets;

  /// URL-test settings (Settings > Routing > URL test): the address every
  /// latency measurement fetches (the tunnel's urltest group and the
  /// measuring core alike), how long one node may take before it counts as
  /// no response, how often the live group re-tests, and how much faster a
  /// node must be before the group switches to it.
  final String urlTestUrl;
  final int urlTestTimeoutSec;
  final int urlTestIntervalSec;
  final int urlTestToleranceMs;

  /// Memory-lean profile for the iOS Network Extension (hard ~50 MB cap):
  /// fewer auto-select nodes, a normal MTU, and no downloaded rule-sets, so the
  /// extension isn't OOM-killed a few seconds into the connection. Desktop and
  /// Android (roomier memory) leave this off and get the full config.
  final bool lean;

  /// Emit the outbound TLS `fragment` / `fragment_fallback_delay` keys (the
  /// ClientHello fragmentation that splits the handshake so DPI can't match the
  /// SNI in one packet). The mobile cores (iOS 1.12.x, Android 1.13.x) accept
  /// these keys; the bundled DESKTOP core does NOT and FATALs on startup with
  /// "outbounds[..].tls.fragment: json: unknown field", which the user saw as
  /// "the core did not come up in time". Desktop turns this off (the uTLS Chrome
  /// fingerprint still applies); every other path keeps it on.
  final bool tlsFragment;

  /// The upstream resolver IP the remote DNS server points at (DoH). Empty
  /// means Nova's default (Cloudflare 1.1.1.1). Matches the native app's DNS
  /// picker: '' / 1.1.1.1 / 8.8.8.8 / 9.9.9.9 / 94.140.14.14.
  final String dns;

  /// Force the gvisor TUN stack (userspace TCP) with a normal MTU, regardless of
  /// [lean]. The `system` stack forwards raw IP and does NOT clamp MSS, so on a
  /// full-device TUN with a jumbo MTU the app advertises an oversized MSS that
  /// the real 1500-MTU path can't carry: TLS handshakes and bulk downloads get
  /// reset ("ERR_CONNECTION_RESET" / traffic stalls). gvisor terminates TCP in
  /// userspace and decouples the app-side MSS from the network path, which is why
  /// iOS already uses it. Android's VpnService hits the exact same wall, so it
  /// sets this too. Desktop keeps the system stack (its host handles MSS fine).
  final bool gvisorStack;

  /// The user's line speed in Mbps. When >0 it turns on Hysteria2's Brutal
  /// congestion control (fixed-rate, loss-tolerant) at these rates, the big
  /// throughput win on throttled links. A node link's own bandwidth wins over
  /// this. 0 = off = BBR (the safe default). Set to the user's REAL line speed:
  /// too high floods and induces loss, too low caps.
  final int hy2UpMbps;
  final int hy2DownMbps;

  /// Per-ISP uTLS fingerprint override. When set (non-empty), it wins over each
  /// node's own pinned fingerprint and the Chrome default, so the app can hand
  /// the DPI-optimal ClientHello for the user's carrier (e.g. Irancell -> chrome,
  /// MCI -> randomized, Rightel -> firefox). Empty/null keeps the per-node value.
  /// The matching `tlsFragment` toggle above is set from the same ISP profile.
  final String? fingerprintOverride;

  /// Whether to auto-apply the per-carrier profile (fingerprint + fragmentation)
  /// at connect time. Set from the Routing setting; the controller runs the
  /// [IspOptimizer] and folds the result back in via [copyWith]. Off on desktop
  /// (no SIM) and whenever the user disables it.
  final bool autoOptimizeCarrier;

  /// Raise the core's log level from `warn` to `info` so the Logs screen shows
  /// what the core is doing per connection, not just its complaints.
  ///
  /// Off by default and deliberately opt-in: at `info` sing-box logs a line for
  /// every connection it routes, which on a phone is a steady stream of work
  /// (formatting, the command socket, the ring buffer) for a screen nobody has
  /// open. A user who is diagnosing something turns it on; everyone else pays
  /// nothing for it.
  final bool verboseCoreLog;

  /// The `log.level` this produces.
  String get logLevel => verboseCoreLog ? 'info' : 'warn';

  /// Apply the SNI-block bypass profile to every clean-IP fronted node in the
  /// config (see [ProxyNode.isCleanIpFronted] and [ProxyNode.hardened]).
  ///
  /// This exists for the day the censor blocks the SNI of `workers.dev` and
  /// `pages.dev` outright, which field reports say has started. The profile
  /// (Go's own TLS with the PattNG cipher list, TLS-record and TCP-segment
  /// fragmentation of the ClientHello) is what got through on those networks in
  /// PattNG. It is not the default because it costs speed and because a browser
  /// fingerprint is the better disguise where the SNI itself is not the trigger,
  /// so the controller turns it on for a subscription only after every node in
  /// it failed to carry traffic, and the user can force it either way.
  final bool hardenTls;

  /// Whether the SNI-block bypass includes the TCP-segment fragment stage (the
  /// recipe's second stage) on top of the TLS-record split.
  ///
  /// True everywhere except Windows. On Windows sing-box implements per-segment
  /// fragmentation with a "wait for the ACK" step that goes through the TCP
  /// EStats API (winiphlpapi), which an unelevated core cannot drive, so the
  /// handshake stalls and the connection never comes up: exactly the "Windows
  /// never connects with the bypass on" report. The TLS-record split, which is
  /// the part that stops DPI matching the SNI in one packet, uses a different
  /// path with no ACK-wait and works. So Windows keeps the record split and
  /// drops the segment split; the desktop controller sets this.
  final bool hardenPacketFragment;

  /// Per-app routing, Android only.
  ///
  /// [includePackages] means "send ONLY these apps through Nova"; anything not
  /// listed keeps its normal connection. [excludePackages] is the mirror: every
  /// app goes through Nova except these. They are mutually exclusive, which
  /// Android enforces anyway (VpnService.Builder throws if both are used), so
  /// the settings model only ever fills one.
  ///
  /// Android is the only platform that can do this. Its VpnService takes an
  /// allow/deny list of packages; iOS reserves per-app VPN for MDM-managed
  /// devices, and the desktop hosts route by process at a different layer. The
  /// native service already reads these off the TUN options (see
  /// NovaVpnService.openTun), so emitting them here is the whole wiring.
  final List<String> includePackages;
  final List<String> excludePackages;

  /// Keep the TUN and add a loopback proxy beside it. Set when per-app routing
  /// is on, so the app can reach its own tunnel to ask where it exits.
  final bool tunWithLocalProxy;

  SingboxRouteOptions copyWith({
    bool? lean,
    bool? localRuleSets,
    String? urlTestUrl,
    int? urlTestTimeoutSec,
    int? urlTestIntervalSec,
    int? urlTestToleranceMs,
    bool? tlsFragment,
    bool? gvisorStack,
    int? hy2UpMbps,
    int? hy2DownMbps,
    String? fingerprintOverride,
    bool? autoOptimizeCarrier,
    bool? verboseCoreLog,
    bool? hardenTls,
    bool? hardenPacketFragment,
    String? bypassFingerprint,
    List<String>? bypassCipherSuites,
    String? bypassFragmentMask,
    String? tunInterfaceName,
    int? mixedInboundPort,
    List<String>? includePackages,
    List<String>? excludePackages,
    bool? tunWithLocalProxy,
  }) =>
      SingboxRouteOptions(
        mode: mode,
        blockAds: blockAds,
        bypassIran: bypassIran,
        bypassLan: bypassLan,
        dns: dns,
        lean: lean ?? this.lean,
        localRuleSets: localRuleSets ?? this.localRuleSets,
        urlTestUrl: urlTestUrl ?? this.urlTestUrl,
        urlTestTimeoutSec: urlTestTimeoutSec ?? this.urlTestTimeoutSec,
        urlTestIntervalSec: urlTestIntervalSec ?? this.urlTestIntervalSec,
        urlTestToleranceMs: urlTestToleranceMs ?? this.urlTestToleranceMs,
        tlsFragment: tlsFragment ?? this.tlsFragment,
        gvisorStack: gvisorStack ?? this.gvisorStack,
        hy2UpMbps: hy2UpMbps ?? this.hy2UpMbps,
        hy2DownMbps: hy2DownMbps ?? this.hy2DownMbps,
        fingerprintOverride: fingerprintOverride ?? this.fingerprintOverride,
        autoOptimizeCarrier: autoOptimizeCarrier ?? this.autoOptimizeCarrier,
        verboseCoreLog: verboseCoreLog ?? this.verboseCoreLog,
        hardenTls: hardenTls ?? this.hardenTls,
        hardenPacketFragment:
            hardenPacketFragment ?? this.hardenPacketFragment,
        bypassFingerprint: bypassFingerprint ?? this.bypassFingerprint,
        bypassCipherSuites: bypassCipherSuites ?? this.bypassCipherSuites,
        bypassFragmentMask: bypassFragmentMask ?? this.bypassFragmentMask,
        tunInterfaceName: tunInterfaceName ?? this.tunInterfaceName,
        mixedInboundPort: mixedInboundPort ?? this.mixedInboundPort,
        includePackages: includePackages ?? this.includePackages,
        excludePackages: excludePackages ?? this.excludePackages,
        tunWithLocalProxy: tunWithLocalProxy ?? this.tunWithLocalProxy,
      );
}

/// Builds a sing-box configuration document from a [ProxyNode].
///
/// Targets the sing-box 1.8–1.11 schema (TUN inbound + DNS + rule-based route
/// with remote rule-sets). This is exactly the JSON the native core consumes;
/// keeping it in Dart means it is unit-tested and shared across every platform
/// host, with the native side only responsible for running it on the TUN fd.
class SingboxConfig {
  const SingboxConfig._();

  // Iran + ad rule-sets — the de-facto standard sources for sing-box on Iranian
  // networks (used when the matching routing toggles are on).
  static const String _adsRuleSet =
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs';
  static const String _geoipIr =
      'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs';
  static const String _geositeIr =
      'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs';

  /// Returns the config as a pretty-printed JSON string.
  static String build(
    ProxyNode node, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    return const JsonEncoder.withIndent('  ').convert(buildMap(node, options: options));
  }

  /// A sing-box config whose only exit is a local SOCKS proxy: the TUN traffic
  /// is forwarded to `127.0.0.1:[socksPort]`, where the Xray core is listening.
  ///
  /// This is the bridge half of the two-core xhttp path: sing-box owns the TUN
  /// (as always) and hands everything to Xray, which speaks the xhttp transport
  /// sing-box cannot. Xray then dials the real server on protected sockets. The
  /// rest of the document (TUN, DNS, route) is the normal one, so ad-blocking and
  /// the Iran bypass still apply to what flows through.
  static String buildXraySocksBridge(
    int socksPort, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    String? directServerIp,
  }) =>
      const JsonEncoder.withIndent('  ').convert(buildXraySocksBridgeMap(
          socksPort,
          options: options,
          directServerIp: directServerIp));

  /// [directServerIp], when set, routes that IP straight out `direct`. On desktop
  /// TUN (whole-device) mode this is what stops an xhttp loop: Xray is a separate
  /// process, so its own connection to the server would be captured by sing-box's
  /// tunnel and fed back into the socks->Xray chain forever. Sending the server IP
  /// direct (Xray dials the resolved IP, so this rule matches it) breaks that
  /// cycle. Harmless in proxy mode, where nothing is captured; pass null there.
  static Map<String, dynamic> buildXraySocksBridgeMap(
    int socksPort, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    String? directServerIp,
    /// The xhttp exit's address, resolved or not. Preferred over
    /// [directServerIp], which only ever accepted an IP and so left the rule
    /// off entirely when a name did not resolve.
    List<String> directServers = const <String>[],
  }) {
    return <String, dynamic>{
      'log': <String, dynamic>{'level': options.logLevel, 'timestamp': true},
      'dns': _dns(options, directDomains: <String>{
        ..._ruleSetHosts,
        ..._directHosts,
      }),
      'inbounds': _inbounds(options),
      'outbounds': <Map<String, dynamic>>[
        // The Xray core's local SOCKS inbound. Tagged `proxy` so the shared route
        // targets it exactly like any real exit.
        <String, dynamic>{
          'type': 'socks',
          'tag': 'proxy',
          'server': '127.0.0.1',
          'server_port': socksPort,
          'version': '5',
        },
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
      ],
      // QUIC stays blocked: the xhttp exit is TCP, and letting UDP escape direct
      // would leak outside the tunnel.
      'route': _routeResolvingForXray(options,
          directServerIp: directServerIp, directServers: directServers),
    };
  }

  /// The normal route, plus a trailing `resolve` action for the two-core xhttp
  /// bridge. sing-box sniffs each connection's domain (TLS SNI / HTTP Host) and,
  /// without this, forwards that domain to Xray's local SOCKS — where Xray, which
  /// has no resolver in this path, fails it ("dns: exchange failed for a name")
  /// and no traffic flows (only the DoH lookups, which already dial an IP, get
  /// through). Resolving the sniffed name back to an IP here — via sing-box's own
  /// DNS, already warm from the app's lookup of the same name — means Xray only
  /// ever receives IPs and never needs to resolve anything. The action is placed
  /// LAST, after the domain-based direct/block rules (so those still match on the
  /// name) and before `final: proxy`, so it only touches proxy-bound connections.
  static Map<String, dynamic> _routeResolvingForXray(SingboxRouteOptions o,
      {String? directServerIp, List<String> directServers = const <String>[]}) {
    final Map<String, dynamic> route = _route(o, blockQuic: true);
    final List<dynamic> rules = route['rules'] as List<dynamic>;
    xhttpDirectRules(rules, <String>[
      if (directServerIp != null && directServerIp.isNotEmpty) directServerIp,
      ...directServers,
    ]);
    rules.add(<String, dynamic>{
      'action': 'resolve',
      'strategy': 'prefer_ipv4',
    });
    return route;
  }

  /// Puts every xhttp exit's address on the `direct` path, ahead of everything.
  ///
  /// This is what stops a TUN loop. Xray is a separate process, so its own dial
  /// to the server is captured by sing-box's tunnel and fed back into the
  /// socks->Xray chain forever. Sending the server straight out breaks the
  /// cycle, and it has to be the first rule so nothing later steers it back.
  ///
  /// Addresses arrive resolved, and an IP is matched as an `ip_cidr` because
  /// that is what Xray will actually dial. A name that failed to resolve is
  /// still matched, by domain, rather than dropped: an omitted rule is not a
  /// missing optimisation here, it is a tunnel that never carries traffic, and
  /// that silent failure is exactly what made this hard to find.
  static void xhttpDirectRules(List<dynamic> rules, List<String> servers) {
    final List<String> ips = <String>[];
    final List<String> domains = <String>[];
    for (final String a in servers) {
      final String v = a.trim();
      if (v.isEmpty) continue;
      if (v.contains(':')) continue; // IPv6: the resolver returns v4
      if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(v)) {
        if (!ips.contains(v)) ips.add(v);
      } else if (!domains.contains(v)) {
        domains.add(v);
      }
    }
    if (domains.isNotEmpty) {
      rules.insert(0, <String, dynamic>{
        'domain': domains,
        'outbound': 'direct',
      });
    }
    if (ips.isNotEmpty) {
      rules.insert(0, <String, dynamic>{
        'ip_cidr': <String>[for (final String ip in ips) '$ip/32'],
        'outbound': 'direct',
      });
    }
  }

  /// Returns the config as a map (useful for tests / further mutation).
  static Map<String, dynamic> buildMap(
    ProxyNode inputNode, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
  }) {
    final ProxyNode node = _maybeHarden(inputNode, options);
    // xhttp / SplitHTTP is Xray-only; sing-box has no implementation, so
    // _transport() would return null and the node would be built as plain TCP,
    // which connects nowhere. buildMultiMap filters these out of the auto pool,
    // but a single pinned node lands here directly. Fail with something the user
    // can act on (connect() surfaces a FormatException message verbatim) rather
    // than handing the core a config that silently cannot work.
    if (node.network == 'xhttp') {
      throw const FormatException(
          'This node uses the xhttp transport, which Nova cannot run. '
          'Ask for a ws, gRPC, httpupgrade, or Reality config instead.');
    }
    // A NaiveProxy server on a self-signed certificate cannot be dialed by this
    // core: the naive outbound has no `insecure` option (cronet validates the
    // certificate itself and there is no way to tell it not to). Building the
    // config anyway produces a core that starts and then fails every dial with
    // a certificate error, which reads as a dead server. Say the real reason.
    if (node.protocol == NodeProtocol.naive && node.allowInsecure) {
      throw const FormatException(
          'This NaiveProxy server uses a self-signed certificate, which the '
          'VPN core cannot accept for NaiveProxy. Ask for a NaiveProxy config '
          'on a real domain, or use one of the server\'s other protocols.');
    }
    return <String, dynamic>{
      'log': <String, dynamic>{'level': options.logLevel, 'timestamp': true},
      'dns': _dns(options,
          directDomains: <String>{
            ..._directDomains(<ProxyNode>[node]),
            ..._ruleSetHosts,
            ..._directHosts,
          }),
      'inbounds': _inbounds(options),
      'outbounds': <Map<String, dynamic>>[
        // AmneziaWG is an endpoint (below), so the proxy slot is only filled by a
        // real outbound protocol; awg keeps just direct/block here.
        if (!node.protocol.isEndpoint)
          _outbound(node,
              fragment: options.tlsFragment,
              hy2Up: options.hy2UpMbps,
              hy2Down: options.hy2DownMbps,
              fingerprintOverride: options.fingerprintOverride,
              hardenPacketFragment: options.hardenPacketFragment),
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        // NB: no 'dns' outbound — it was removed in sing-box 1.13 (Android's
        // core). DNS is hijacked to the DNS module via a route rule action
        // instead (see _route), which works on both 1.12 (iOS) and 1.13.
      ],
      // sing-box carries WireGuard/AmneziaWG as an endpoint. Tagged 'proxy' so
      // route.final / dns.detour reach it with no other change.
      if (node.protocol.isEndpoint)
        'endpoints': <Map<String, dynamic>>[_endpoint(node, tag: 'proxy')],
      'route': _route(options, blockQuic: !node.protocol.isUdpNative),
    };
  }

  /// The most nodes we ever put behind the auto-selector. The iOS Network
  /// Extension runs under a hard ~50 MB memory cap, and every extra outbound is
  /// a live dialer it has to hold; a few dozen of the subscription's nodes is
  /// plenty to find a fast one without risking the extension being killed.
  static const int kMaxAutoNodes = 24;

  /// Like [build], but for a whole subscription: wires every node behind a
  /// `urltest` tagged `proxy` so the core continuously measures latency and
  /// routes through the fastest one. Falls back to the single-node [build] when
  /// only one node is given. The rest of the document (route, DNS) is identical
  /// because the auto-selector keeps the `proxy` tag the rest of the config
  /// already targets.
  static String buildMulti(
    List<ProxyNode> nodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    bool includeXhttp = false,
    int xhttpBasePort = 10808,
  }) {
    return const JsonEncoder.withIndent('  ').convert(buildMultiMap(nodes,
        options: options,
        includeXhttp: includeXhttp,
        xhttpBasePort: xhttpBasePort));
  }

  /// The nodes that actually end up behind the auto-selector, in the exact order
  /// they are tagged `node-0`, `node-1`, ... in the config, after hardening,
  /// dropping cores the transport can't run, pushing gRPC to the back, deduping,
  /// and applying the per-platform cap.
  ///
  /// Exposed so the controller can map the core's per-node urltest results (which
  /// come back keyed by those `node-i` tags) back to real nodes, and show a live
  /// "which server actually works" latency once the tunnel is up. The keys line
  /// up with [orderedMultiNodeKeys].
  static List<ProxyNode> pickedMultiNodes(
    List<ProxyNode> inputNodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    bool includeXhttp = false,
    int? poolCap,
  }) {
    final List<ProxyNode> nodes =
        inputNodes.map((ProxyNode n) => _maybeHarden(n, options)).toList();
    // The lean (iOS) path trims the node pool to stay under the extension's
    // ~50MB memory cap. Fewer idle outbounds (each holds a periodic urltest
    // probe) means more headroom for the throughput burst of a speed test, which
    // is what was pushing the extension over the limit and dropping the tunnel.
    // 12 is still plenty for the urltest to find a fast exit; roomier hosts
    // (desktop/Android) use the full budget.
    // [poolCap] overrides the budget: the measuring core (see buildMeasureMap)
    // wants every node, not the first 24.
    final int cap = poolCap ?? (options.lean ? 12 : kMaxAutoNodes);
    // Drop transports the sing-box core can't carry at all (xhttp / SplitHTTP is
    // Xray only) so they never sit in the urltest pool as dead exits.
    final List<ProxyNode> usable = nodes
        .where((ProxyNode n) =>
            n.network != 'xhttp' &&
            // Same reason as buildMap: the naive outbound cannot skip
            // certificate validation, so a self-signed naive server would sit
            // in the pool as a dead exit.
            !(n.protocol == NodeProtocol.naive && n.allowInsecure))
        .toList();
    // gRPC is a softer case: sing-box speaks standard gRPC (a real external gRPC
    // server works), but the Nova worker's gRPC is Xray "gun" framing that
    // sing-box can't talk to, so Nova gRPC nodes fail to connect. We can't tell
    // the two apart, so instead of dropping gRPC we push it to the back: Auto
    // fills its pool with ws/Trojan first (and never opens on a dead gRPC node),
    // while a sub that is *only* gRPC still gets used. Order within each group is
    // preserved, so the caller's ping ranking still holds.
    final Iterable<ProxyNode> nonGrpc =
        usable.where((ProxyNode n) => n.network != 'grpc');
    final Iterable<ProxyNode> grpc =
        usable.where((ProxyNode n) => n.network == 'grpc');
    // xhttp is Xray-only. When the combined core is available ([includeXhttp]),
    // keep the VLESS-over-xhttp nodes and place them at the BACK of the pool:
    // sing-box reaches them through a local Xray socks inbound, so a real
    // sing-box exit is always cheaper and should fill the measured pool first.
    // A non-VLESS xhttp node still can't be translated, so it stays dropped.
    final List<ProxyNode> xhttp = includeXhttp
        ? nodes
            .where((ProxyNode n) =>
                n.network == 'xhttp' && n.protocol == NodeProtocol.vless)
            .toList()
        : const <ProxyNode>[];
    final List<ProxyNode> ordered = options.hardenTls
        // Bypass on: a domain-addressed node can't pass the SNI block that is the
        // whole reason the bypass is on, so it would just sit in the limited pool
        // failing (and, on iOS where the pool is small, crowd out the clean-IP
        // nodes that actually work and get a live ping). Let the clean-IP fronted
        // nodes fill the measured pool first.
        ? <ProxyNode>[
            ...nonGrpc.where((ProxyNode n) => n.isCleanIpFronted),
            ...nonGrpc.where((ProxyNode n) => !n.isCleanIpFronted),
            ...grpc,
            ...xhttp,
          ]
        : <ProxyNode>[...nonGrpc, ...grpc, ...xhttp];
    // NB: never fall back to the unfiltered `nodes` here. Doing so reintroduced
    // the xhttp nodes, and without [includeXhttp] they were then built as plain
    // TCP exits that could not connect.
    return _dedupe(ordered).take(cap).toList();
  }

  /// The stable node keys for [pickedMultiNodes], in `node-i` tag order. Empty
  /// when a single-node profile is built (there is no urltest group then).
  static List<String> orderedMultiNodeKeys(
    List<ProxyNode> inputNodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    bool includeXhttp = false,
    int? poolCap,
    bool forceGroup = false,
  }) {
    final List<ProxyNode> picked = pickedMultiNodes(inputNodes,
        options: options, includeXhttp: includeXhttp, poolCap: poolCap);
    if (picked.length < 2 && !forceGroup) return const <String>[];
    return <String>[for (final ProxyNode n in picked) proxyNodeKey(n)];
  }

  /// The pool budget for a measuring run: every node a subscription is likely
  /// to carry, with a ceiling so a pathological list cannot start a core with
  /// thousands of idle outbounds.
  static const int kMeasurePoolCap = 200;

  /// A config for the MEASURING core: no TUN, no system proxy, no routing and
  /// no DNS module, just every usable node as a plain outbound, a local `mixed`
  /// inbound (so the core has an inbound at all) and the Clash API on
  /// [clashPort], which is how [MeasureRunner] tests one node at a time.
  ///
  /// This is what turns "not testable" into a number for nodes the outside
  /// probe cannot judge (Reality, obfuscated Hysteria2, SS2022, xhttp-less
  /// VLESS on a clean IP): the core dials each one exactly as a tunnel would
  /// and reports the round-trip, no tunnel required. Same builder as the
  /// auto-select config, so a node measures exactly as it would run.
  ///
  /// Three things are deliberately stripped from the tunnel's config, because
  /// a measuring core has no traffic to route and every one of them costs
  /// startup time the user waits through before the first number appears:
  ///
  ///  * the `urltest` group. sing-box sweeps the whole pool concurrently the
  ///    moment such a group starts, and that cold sweep is exactly the number
  ///    that made mieru and NaiveProxy read 400-800ms: both pay a full session
  ///    or TLS+HTTP/2 setup on their first dial, under contention with every
  ///    other node's first dial. [MeasureRunner] warms each node and reports
  ///    the second, honest figure instead.
  ///  * the DNS module. Its remote resolver is reached *through* the proxy and
  ///    its local one is DoH; neither is needed to dial a node, and both add a
  ///    round trip. Without a `dns` block sing-box uses the system resolver,
  ///    which is what a dial wants anyway.
  ///  * the rule-sets (geosite-ir, geosite-ads). Megabytes to load and, on
  ///    iOS, megabytes to carry over the method channel, to route traffic this
  ///    core will never carry.
  ///
  /// Returns the config and the `node-i` tag -> stable node key map the
  /// controller needs to land results on the right rows. Throws
  /// [FormatException] when no node can be measured (all xhttp).
  static ({
    Map<String, dynamic> config,
    Map<String, String> tagKeys,
    Map<String, int> endpointPorts,
  }) buildMeasureMap(
    List<ProxyNode> inputNodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    required int mixedPort,
    required int clashPort,
    /// First local port for the per-endpoint probe inbounds (see below).
    int endpointBasePort = 19200,
    // With [includeXhttp] the xhttp nodes sit in the pool as local socks
    // outbounds to an Xray instance the host runs alongside (one inbound per
    // node from [xhttpBasePort] up, see XrayConfig.buildMulti), so they get
    // measured too instead of reading "not testable".
    bool includeXhttp = false,
    int xhttpBasePort = 10808,
  }) {
    final List<ProxyNode> picked = pickedMultiNodes(inputNodes,
        options: options, poolCap: kMeasurePoolCap, includeXhttp: includeXhttp);
    if (picked.isEmpty) {
      throw const FormatException(
          'None of these servers use a transport Nova can measure.');
    }
    final Map<String, dynamic> cfg = buildMultiMap(picked,
        options: options,
        poolCap: kMeasurePoolCap,
        forceGroup: true,
        includeXhttp: includeXhttp,
        xhttpBasePort: xhttpBasePort);
    final List<String> keys = orderedMultiNodeKeys(picked,
        options: options,
        poolCap: kMeasurePoolCap,
        forceGroup: true,
        includeXhttp: includeXhttp);
    final Map<String, String> tagKeys = <String, String>{
      for (int i = 0; i < keys.length; i++) 'node-$i': keys[i],
    };
    cfg['inbounds'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'mixed',
        'tag': 'measure-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
    ];
    // Drop the auto-select group: see the note above. The node outbounds keep
    // their `node-i` tags, which is all the Clash API needs to test one.
    final List<Map<String, dynamic>> outs =
        (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
    outs.removeWhere((Map<String, dynamic> o) => o['tag'] == 'proxy');
    // A resolver, and only a resolver. The tunnel's DNS module is dropped (its
    // rule-sets and its through-the-proxy `remote` server are no use here) but
    // something has to turn a server's hostname into an address, and on mobile
    // there is nothing else: NovaMeasure returns a null localDNSTransport on
    // both Android and iOS, so a measuring core with no `dns` block cannot
    // resolve at all. Removing this block made every domain-addressed server
    // report "no response" in about 50ms while bare-IP servers still worked,
    // which is exactly how it got past testing against a free list that is all
    // bare IPs.
    //
    // IP-addressed DoH over `direct`, so it needs no bootstrap resolver and
    // cannot loop back through the proxy it is measuring.
    cfg['dns'] = <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        // No detour: see the note in _dns. A DNS server without one dials
        // directly, which is what this needs, and naming the direct outbound
        // explicitly is fatal at startup in the typed format.
        <String, dynamic>{
          'type': 'https',
          'tag': 'local',
          'server': '223.5.5.5',
        },
      ],
      'final': 'local',
      'strategy': 'prefer_ipv4',
    };
    // AmneziaWG and WireGuard nodes need their own way to be measured.
    //
    // They are sing-box `endpoints`, not outbounds. The Clash API lists them
    // (as type AmneziaWG) so they look testable, but asking it for a delay on
    // one fails instantly and the core never even attempts a dial: no
    // "outbound connection to ..." line is logged at all. The result was that
    // every AmneziaWG server read "no response" while connecting to the very
    // same server worked, which is what a user reported.
    //
    // So each endpoint gets a local inbound of its own, and a route rule
    // pinning that inbound to it. Measuring one is then a plain timed request
    // through its port, which exercises the real dial path. Verified against a
    // live server: an endpoint the Clash API refused to test answered in 245ms
    // this way.
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[];
    final Map<String, int> endpointPorts = <String, int>{};
    final List<dynamic> eps =
        (cfg['endpoints'] as List<dynamic>?) ?? const <dynamic>[];
    final List<Map<String, dynamic>> ins =
        (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
    for (int i = 0; i < eps.length; i++) {
      final Object? e = eps[i];
      if (e is! Map) continue;
      final String? tag = e['tag'] as String?;
      if (tag == null || tag.isEmpty) continue;
      final int port = endpointBasePort + i;
      final String inTag = 'measure-ep-$i';
      ins.add(<String, dynamic>{
        'type': 'mixed',
        'tag': inTag,
        'listen': '127.0.0.1',
        'listen_port': port,
      });
      rules.add(<String, dynamic>{
        'inbound': <String>[inTag],
        'outbound': tag,
      });
      endpointPorts[tag] = port;
    }
    cfg['route'] = <String, dynamic>{
      'rules': rules,
      'final': 'direct',
      'auto_detect_interface': true,
    };
    final Map<String, dynamic> experimental =
        (cfg['experimental'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
    experimental['clash_api'] = <String, dynamic>{
      'external_controller': '127.0.0.1:$clashPort',
    };
    cfg['experimental'] = experimental;
    return (config: cfg, tagKeys: tagKeys, endpointPorts: endpointPorts);
  }

  /// The xhttp nodes that will sit in the auto pool, in the same order they take
  /// in [pickedMultiNodes]/[buildMultiMap]. The controller feeds these to
  /// [XrayConfig.buildMulti] so the i-th xhttp node's Xray socks inbound port
  /// lines up with the socks outbound sing-box emits for it.
  static List<ProxyNode> pickedXhttpNodes(
    List<ProxyNode> inputNodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    int? poolCap,
  }) =>
      pickedMultiNodes(inputNodes,
              options: options, includeXhttp: true, poolCap: poolCap)
          .where((ProxyNode n) => n.network == 'xhttp')
          .toList();

  static Map<String, dynamic> buildMultiMap(
    List<ProxyNode> inputNodes, {
    SingboxRouteOptions options = const SingboxRouteOptions(),
    bool includeXhttp = false,
    int xhttpBasePort = 10808,
    int? poolCap,
    bool forceGroup = false,
    /// The xhttp exits' addresses, already resolved where possible. Needed in
    /// TUN mode for the same reason the single-node path needs it: without them
    /// Xray's own dial loops back through the tunnel. Ignored when the pool has
    /// no xhttp nodes.
    List<String> xhttpDirectServers = const <String>[],
  }) {
    final List<ProxyNode> picked = pickedMultiNodes(inputNodes,
        options: options, includeXhttp: includeXhttp, poolCap: poolCap);
    if (picked.isEmpty) {
      throw const FormatException(
          'None of this subscription\'s nodes use a transport Nova can run '
          '(they are all xhttp). Ask for ws, gRPC, httpupgrade, or Reality.');
    }
    // A single non-xhttp survivor collapses to the plain single-node config.
    // A single xhttp survivor cannot (sing-box has no xhttp outbound); it falls
    // through to the socks-wrapped pool below, which handles a one-entry urltest.
    // [forceGroup] keeps the urltest group even for one node: the measuring
    // core reads results off the group stream, which has no entry for a lone
    // outbound.
    if (picked.length == 1 && picked.first.network != 'xhttp' && !forceGroup) {
      return buildMap(picked.first, options: options);
    }
    final List<Map<String, dynamic>> nodeOutbounds = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> nodeEndpoints = <Map<String, dynamic>>[];
    final List<String> tags = <String>[];
    int xhttpSeq = 0;
    for (int i = 0; i < picked.length; i++) {
      final String tag = 'node-$i';
      tags.add(tag);
      // An xhttp node runs on the Xray core; sing-box reaches it through a local
      // Xray socks inbound (one per xhttp node, at xhttpBasePort + its order).
      // As a plain socks outbound it sits in the urltest pool like any exit, so
      // it gets measured, picked and shown with a live ping through the same
      // command surface. The port order here matches XrayConfig.buildMulti.
      if (picked[i].network == 'xhttp') {
        nodeOutbounds.add(<String, dynamic>{
          'type': 'socks',
          'tag': tag,
          'server': '127.0.0.1',
          'server_port': xhttpBasePort + xhttpSeq,
          'version': '5',
        });
        xhttpSeq++;
        continue;
      }
      // AmneziaWG nodes are endpoints; the urltest still lists their tag, so the
      // auto-selector measures and picks them alongside outbound nodes.
      if (picked[i].protocol.isEndpoint) {
        nodeEndpoints.add(_endpoint(picked[i], tag: tag));
      } else {
        nodeOutbounds.add(_outbound(picked[i],
            tag: tag,
            fragment: options.tlsFragment,
            hy2Up: options.hy2UpMbps,
            hy2Down: options.hy2DownMbps,
            fingerprintOverride: options.fingerprintOverride,
            hardenPacketFragment: options.hardenPacketFragment));
      }
    }
    return <String, dynamic>{
      'log': <String, dynamic>{'level': options.logLevel, 'timestamp': true},
      'dns': _dns(options,
          directDomains: <String>{
            ..._directDomains(picked),
            ..._ruleSetHosts,
            ..._directHosts,
          }),
      'inbounds': _inbounds(options),
      'outbounds': <Map<String, dynamic>>[
        // Auto-pick the fastest node and keep tracking it. Every node exits the
        // same Cloudflare worker, so their measured latencies all sit within a
        // few hundred ms of each other. That is exactly why the old 800ms
        // tolerance backfired: no node was ever 800ms faster than another, so the
        // urltest could never move off its initial pick (node-0, an arbitrary
        // first entry), and Auto looked "stuck on a slow server". A tight band
        // lets it settle on the genuinely lowest-latency exit. Connection drops
        // (the reason the band was widened) are already prevented by
        // interrupt_exist_connections: false below, so a small tolerance is safe.
        <String, dynamic>{
          'type': 'urltest',
          'tag': 'proxy',
          'outbounds': tags,
          // Plain http on purpose: the test already rides inside the
          // encrypted tunnel, and an https target adds a second TLS
          // handshake (one more round trip through the proxy) to every
          // measurement. That extra handshake, plus our fragmented ClientHello
          // to the proxy, is why Nova's pings read far above Karing's for the
          // same server; this takes the avoidable half out.
          'url': options.urlTestUrl.trim().isEmpty ? kDefaultUrlTestUrl : options.urlTestUrl.trim(),
          // Re-test every 3 min so a node that degrades is dropped reasonably
          // soon, without hammering the exits.
          'interval': '${options.urlTestIntervalSec.clamp(10, 86400)}s',
          // 50ms band: switch to a node only when it is meaningfully faster than
          // the current pick (>50ms), which ignores trivial jitter but still
          // homes in on the lowest-latency exit instead of clinging to node-0.
          'tolerance': options.urlTestToleranceMs.clamp(0, 5000),
          'idle_timeout': '30m0s',
          // Never tear down live connections when the pick changes: an in-flight
          // download or stream stays on its node instead of being cut.
          'interrupt_exist_connections': false,
        },
        ...nodeOutbounds,
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
        // No 'dns' outbound (removed in sing-box 1.13); DNS is hijacked via a
        // route rule action instead (see _route).
      ],
      if (nodeEndpoints.isNotEmpty) 'endpoints': nodeEndpoints,
      // If any exit in the pool is UDP-native (Hysteria2/TUIC/AmneziaWG), let
      // QUIC flow; otherwise (an all-worker pool) keep blocking it.
      'route': () {
        final Map<String, dynamic> r = _route(options,
            blockQuic: !picked.any((ProxyNode n) => n.protocol.isUdpNative));
        if (xhttpDirectServers.isNotEmpty) {
          xhttpDirectRules(r['rules'] as List<dynamic>, xhttpDirectServers);
        }
        return r;
      }(),
    };
  }

  /// Drops duplicate endpoints (same server:port:path) so the auto-selector
  /// isn't full of identical hops, keeping the node budget for real variety.
  static List<ProxyNode> _dedupe(List<ProxyNode> nodes) {
    final Set<String> seen = <String>{};
    final List<ProxyNode> out = <ProxyNode>[];
    for (final ProxyNode n in nodes) {
      final String key = '${n.server}:${n.port}:${n.wsPath ?? ''}';
      if (seen.add(key)) out.add(n);
    }
    return out;
  }

  /// What the core listens on: a TUN that takes the whole device, or, in proxy
  /// mode, a loopback SOCKS5 + HTTP port that takes only what is pointed at it.
  ///
  /// Per-app routing gets BOTH. With an allow/deny list the app itself is
  /// normally outside its own tunnel, so anything Nova measures on its own
  /// sockets measures the user's real line: the dashboard read back the user's
  /// own IP and country and presented them as the exit. A loopback inbound
  /// alongside the TUN gives the app a way into its own tunnel to ask, without
  /// putting Nova into the user's app list and changing what they chose.
  static List<Map<String, dynamic>> _inbounds(SingboxRouteOptions o) {
    if (o.mixedInboundPort == null) {
      return <Map<String, dynamic>>[_tunInbound(o)];
    }
    if (o.tunWithLocalProxy) {
      return <Map<String, dynamic>>[_tunInbound(o), _mixedInbound(o)];
    }
    return <Map<String, dynamic>>[_mixedInbound(o)];
  }

  static Map<String, dynamic> _mixedInbound(SingboxRouteOptions o) =>
      <String, dynamic>{
        'type': 'mixed',
        'tag': 'proxy-in',
        // Loopback only. A phone on a shared network must not become an open
        // relay for everyone else on that network.
        'listen': '127.0.0.1',
        'listen_port': o.mixedInboundPort,
      };

  static Map<String, dynamic> _tunInbound(SingboxRouteOptions o) =>
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        if (o.tunInterfaceName != null)
          'interface_name': o.tunInterfaceName,
        // sing-box 1.12 removed the legacy `inet4_address`/`inet6_address`
        // fields in favour of a single `address` list. Both cores we ship
        // (iOS 1.12.x, Android 1.13.x) are past that cut, so the old field
        // logged "legacy tun address fields ... removed in sing-box 1.12.0";
        // `address` is the current, warning-free form.
        'address': <String>['172.19.0.1/30'],
        // iOS (lean) uses the gvisor stack: the system stack forwards raw IP
        // packets, so on the iOS extension large download packets fragment and
        // get dropped (bulk transfers crawl to ~0 while small requests still
        // work). gvisor terminates TCP in userspace (no fragmentation) and is
        // the standard for the iOS Network Extension. We keep it rather than
        // sing-box's `mixed` stack, which reintroduces that fragmentation risk.
        //
        // MTU: 4064 on the gvisor path (iOS, matching Karing which runs the same
        // core in the same ~50MB NE; and Android) instead of 1500. With gvisor a
        // larger TUN MTU means fewer packets/syscalls per byte, so bulk
        // throughput improves without the fragmentation drops the system stack
        // would hit. Only DESKTOP keeps the system stack + jumbo 9000 MTU: its
        // host clamps MSS correctly, so it survives what a VpnService/NE can't.
        'mtu': (o.lean || o.gvisorStack) ? 4064 : 9000,
        'auto_route': true,
        'strict_route': true,
        // Per-app routing. Only ever one of the two is non-empty: Android's
        // VpnService.Builder rejects a config that uses both.
        if (o.includePackages.isNotEmpty)
          'include_package': <String>[...o.includePackages],
        if (o.excludePackages.isNotEmpty)
          'exclude_package': <String>[...o.excludePackages],
        'stack': (o.lean || o.gvisorStack) ? 'gvisor' : 'system',
        // Sniffing is NOT set here anymore. sing-box 1.13 removed the
        // inbound-level `sniff`/`sniff_override_destination` fields ("legacy
        // inbound fields ... removed in sing-box 1.13.0"), which was fatal on
        // the Android 1.13 core (inbound[0] failed to initialize, so the tunnel
        // never came up). Sniffing now lives in the route as a `{action: sniff}`
        // rule (see _route); that is the supported form on 1.11+/1.12/1.13.
        //
        // NOTE: platform.http_proxy (advertising a system HTTP proxy via
        // NEProxySettings) was tried in build 29 and is disabled again, it is a
        // prime suspect for build 29's broken browsing (all HTTP/HTTPS was routed
        // to the proxy port; if that listener misbehaves, browsers fail while
        // Telegram, which ignores the system proxy, keeps working). The native
        // openTun handler stays (dormant: isHTTPProxyEnabled() is now false) so
        // re-enabling is a one-line config change once the base path is verified.
      };

  static Map<String, dynamic> _dns(
    SingboxRouteOptions o, {
    Iterable<String> directDomains = const <String>[],
  }) {
    // The resolver for proxied (remote) DNS, over DoH so Iran's DNS tampering
    // can't touch it, reached THROUGH the proxy. IP-based, so it needs no
    // bootstrap resolver.
    //
    // Default is Google (8.8.8.8), NOT Cloudflare (1.1.1.1): the Nova exit is a
    // Cloudflare Worker, and a Worker cannot relay to Cloudflare's own endpoints
    // (loop protection), so a DoH query to 1.1.1.1 through the worker silently
    // fails. With no DNS, only apps that dial hardcoded IPs (Telegram) work
    // while browsers/Instagram can't resolve anything — the exact "only Telegram
    // opens" report. 8.8.8.8 is off-Cloudflare, so the worker can reach it.
    final String remote = o.dns.isEmpty ? '8.8.8.8' : o.dns;
    final List<String> direct = directDomains.toList();

    return <String, dynamic>{
      // The typed server format, not the `address: "https://..."` URL form.
      //
      // sing-box deprecated the URL form in 1.12 and REMOVES it in 1.14. On the
      // desktop CLI core it was already fatal, not a warning: the core refused
      // to start at all unless ENABLE_DEPRECATED_LEGACY_DNS_SERVERS was set,
      // which is a thing Nova was carrying purely to keep this block working.
      // That variable is gone now, and so is the deadline.
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'https',
          'tag': 'remote',
          'server': remote,
          'detour': 'proxy',
        },
        // No detour. It used to say `detour: "direct"`, which the typed format
        // rejects outright at STARTUP (not at parse time): "detour to an empty
        // direct outbound makes no sense". A DNS server with no detour dials
        // directly and does not pass through the route at all, which is what
        // that detour was for. Verified rather than assumed: with the route's
        // final outbound pointed at a dead proxy, this server still resolved.
        <String, dynamic>{
          'type': 'https',
          'tag': 'local',
          'server': '223.5.5.5',
        },
        // No 'block' server any more: `rcode://success` was a server in the old
        // form and is a RULE ACTION in the new one. See the ad rule below.
      ],
      'rules': <Map<String, dynamic>>[
        // The proxy's own server domains MUST resolve directly. Otherwise
        // resolving them falls through to `remote`, which is reached *through*
        // the proxy, which needs them resolved first — sing-box aborts startup
        // with "DNS query loopback in transport[remote]" and nothing connects.
        if (direct.isNotEmpty)
          <String, dynamic>{'domain': direct, 'server': 'local'},
        // These reference rule-sets that _route() defines (remote on the full
        // path, bundled-local on the lean/iOS path), so both can resolve Iran
        // domains for real and drop ads.
        // Answer ad domains with an empty success rather than sending them
        // anywhere. NOERROR is the new spelling of what `rcode://success` did:
        // the query succeeds with no address, so the client stops instead of
        // retrying the way it would after a refusal or NXDOMAIN.
        if (o.blockAds && o.mode != SingboxMode.direct)
          <String, dynamic>{
            'rule_set': 'geosite-ads',
            'action': 'predefined',
            'rcode': 'NOERROR',
          },
        if (o.bypassIran && o.mode == SingboxMode.rule)
          <String, dynamic>{'rule_set': 'geosite-ir', 'server': 'local'},
      ],
      'final': o.mode == SingboxMode.direct ? 'local' : 'remote',
      'strategy': 'prefer_ipv4',
    };
  }

  static Map<String, dynamic> _outbound(
    ProxyNode n, {
    String tag = 'proxy',
    bool fragment = true,
    int hy2Up = 0,
    int hy2Down = 0,
    String? fingerprintOverride,
    bool hardenPacketFragment = true,
  }) {
    final Map<String, dynamic> o = <String, dynamic>{
      'type': n.protocol.singboxType,
      'tag': tag,
      'server': n.server,
      'server_port': n.port,
    };
    switch (n.protocol) {
      case NodeProtocol.vless:
        o['uuid'] = n.uuid;
        final String? flow = _singboxFlow(n.flow);
        if (flow != null) o['flow'] = flow;
      case NodeProtocol.trojan:
        o['password'] = n.password;
      case NodeProtocol.shadowsocks:
        o['method'] = n.method;
        o['password'] = n.password;
      case NodeProtocol.vmess:
        o['uuid'] = n.uuid;
        o['alter_id'] = n.vmessAlterId;
        o['security'] = n.vmessSecurity ?? 'auto';
      case NodeProtocol.hysteria2:
        if (n.password != null) o['password'] = n.password;
        if (n.obfsType != null && n.obfsType!.isNotEmpty) {
          o['obfs'] = <String, dynamic>{
            'type': n.obfsType,
            'password': n.obfsPassword ?? '',
          };
        }
        // Bandwidth hints => Brutal congestion control (fixed-rate, loss-tolerant),
        // the throughput win on throttled links. The node link's own value wins;
        // else the user's app-wide line-speed setting. Omitted => BBR.
        final int up = (n.hy2UpMbps ?? 0) > 0 ? n.hy2UpMbps! : hy2Up;
        final int down = (n.hy2DownMbps ?? 0) > 0 ? n.hy2DownMbps! : hy2Down;
        if (up > 0) o['up_mbps'] = up;
        if (down > 0) o['down_mbps'] = down;
      case NodeProtocol.tuic:
        o['uuid'] = n.uuid;
        o['password'] = n.password ?? '';
        o['congestion_control'] = n.congestionControl ?? 'bbr';
        o['udp_relay_mode'] = n.udpRelayMode ?? 'native';
      case NodeProtocol.socks:
        o['version'] = '5';
        if (n.uuid != null) o['username'] = n.uuid; // uuid slot = username
        if (n.password != null) o['password'] = n.password;
      case NodeProtocol.http:
        if (n.uuid != null) o['username'] = n.uuid;
        if (n.password != null) o['password'] = n.password;
      case NodeProtocol.naive:
        // HTTP/2 CONNECT inside TLS. The credentials are a plain username and
        // password (the parser puts the username in the uuid slot, as socks and
        // http already do), and the transport is fixed: naive has no ws/grpc
        // variant, so the transport block below must not add one.
        if (n.uuid != null) o['username'] = n.uuid;
        if (n.password != null) o['password'] = n.password;
      case NodeProtocol.mieru:
        // enfein/mieru outbound (ported into the core from mbox). Username sits
        // in the uuid slot like socks/http/naive; transport is TCP/UDP and the
        // multiplexing level rides on the node. server/server_port set above.
        if (n.uuid != null) o['username'] = n.uuid;
        if (n.password != null) o['password'] = n.password;
        o['transport'] = n.mieruTransport.toUpperCase() == 'UDP' ? 'UDP' : 'TCP';
        o['multiplexing'] = n.mieruMultiplexing;
      case NodeProtocol.awg:
        // AmneziaWG is a sing-box endpoint, not an outbound; callers must use
        // _endpoint(). Reaching here is a wiring bug.
        throw StateError('awg is an endpoint, not an outbound');
    }
    if (n.tls) {
      o['tls'] = _tls(n,
          fragment: fragment,
          fingerprintOverride: fingerprintOverride,
          hardenPacketFragment: hardenPacketFragment);
    }
    // QUIC-native protocols (Hysteria2/TUIC) carry no ws/grpc transport, and
    // naive's transport is fixed by the protocol (HTTP/2 over TLS): a `type=tcp`
    // in the link is v2rayN filling in a field naive does not have, and emitting
    // a transport block for it makes the outbound invalid.
    if (!n.protocol.isUdpNative && n.protocol != NodeProtocol.naive) {
      final Map<String, dynamic>? transport = _transport(n);
      if (transport != null) o['transport'] = transport;
    }
    return o;
  }

  /// The sing-box `awg` endpoint for an AmneziaWG node, tagged so routing (which
  /// always targets tag strings, never types) reaches it exactly like a proxy
  /// outbound. The junk params (jc/jmin/jmax/s1-4/h1-4) and peer come straight
  /// from the stored `.conf`.
  static Map<String, dynamic> _endpoint(ProxyNode n, {String tag = 'proxy'}) {
    return AwgConfig.parseConf(n.awgConf ?? '').toEndpoint(tag);
  }

  static Map<String, dynamic> _tls(
    ProxyNode n, {
    bool fragment = true,
    String? fingerprintOverride,
    bool hardenPacketFragment = true,
  }) {
    // Always forge a real browser's TLS ClientHello via uTLS, defaulting to
    // Chrome when the link didn't pin a fingerprint. Without this, a plain
    // worker VLESS node hands out Go's stock TLS fingerprint, which Iran's DPI
    // can flag as "not a browser"; a Chrome uTLS handshake blends in with normal
    // HTTPS. This is the client-side half of what Xray-based clients lean on;
    // the other half, ClientHello fragmentation, is applied just below (both the
    // iOS 1.12.x and Android 1.13.x cores now support it).
    // Reality already mandates uTLS, so this just makes every other TLS node
    // match that behaviour.
    // Per-ISP override wins over the node's pinned fingerprint, which wins over
    // the Chrome default. Reality keeps its own uTLS handshake, but the override
    // still applies to it (it only swaps which browser profile is forged).
    final String fingerprint = _singboxFingerprint(
        (fingerprintOverride != null && fingerprintOverride.isNotEmpty)
            ? fingerprintOverride
            : (n.fingerprint != null && n.fingerprint!.isNotEmpty)
                ? n.fingerprint!
                : 'chrome');
    // NaiveProxy's TLS belongs to cronet (Chromium's network stack), not to
    // sing-box: measured against the 1.13.13 core, the naive outbound rejects
    // `alpn`, `utls`, `fragment` AND `insecure` outright ("<x> is not supported
    // on naive outbound"), so its block is the bare minimum. Chromium's own
    // ClientHello is the fingerprint, which is the point of the protocol.
    if (n.protocol == NodeProtocol.naive) {
      return <String, dynamic>{
        'enabled': true,
        'server_name': n.sni ?? n.server,
      };
    }
    // QUIC protocols (Hysteria2, TUIC) do their TLS inside QUIC. sing-box's
    // QUIC dialer takes a standard TLS config and refuses a uTLS one ("open
    // connection ... using outbound/hysteria2: unsupported usage for uTLS"),
    // which is why every Hysteria2 node failed to connect, salamander or not
    // (reproduced against a local sing-box hysteria2 inbound). Record
    // fragmentation is a TCP trick too. So: plain TLS, SNI, insecure, ALPN.
    if (n.protocol.isUdpNative) {
      return <String, dynamic>{
        'enabled': true,
        'server_name': n.sni ?? n.server,
        if (n.allowInsecure) 'insecure': true,
        if (n.alpn.isNotEmpty) 'alpn': n.alpn,
      };
    }
    // The SNI-block bypass profile. `fp=unsafe` in Xray means no browser
    // fingerprint at all: Go's own TLS with the given cipher list. So uTLS is
    // off, the cipher list is what the link (or the app's default) says.
    // `record_fragment` (the recipe's first stage: the ClientHello split into
    // many TLS records) is always on, since that is what stops DPI matching the
    // SNI in one packet. The `fragment` TCP-segment split (its second stage) is
    // gated on [hardenPacketFragment] because its ACK-wait breaks on an
    // unelevated Windows core. The exact 5/94/1-byte record and 109/1-byte
    // segment sizes are not expressible here, which is the known gap against the
    // field-tested PattNG configuration. Reality keeps its own handshake.
    if (n.isHardenedTls && !n.isReality) {
      final List<String> suites =
          (n.cipherSuites.isEmpty ? kBypassCipherSuites : n.cipherSuites)
              .where(_coreCipherSuites.contains)
              .toList();
      return <String, dynamic>{
        'enabled': true,
        'server_name': n.sni ?? n.server,
        if (n.allowInsecure) 'insecure': true,
        if (n.alpn.isNotEmpty) 'alpn': n.alpn,
        if (suites.isNotEmpty) 'cipher_suites': suites,
        // Exact, byte-for-byte fragmentation via the patched core's
        // `nova_fragment` (a port of Xray's finalmask). The stages come from the
        // node's own `fm` mask when the link carried one, else the field-tested
        // default. This is what matches PattNG on strict DPI, where sing-box's
        // own random-point `record_fragment` was not enough. On Windows the
        // TCP-segment stage is dropped, since only that stage needs the
        // ACK-wait an unelevated Windows core cannot drive; the TLS-record
        // stage, which defeats the SNI match, stays.
        'nova_fragment': _novaFragmentStages(n, hardenPacketFragment),
        'utls': <String, dynamic>{'enabled': false},
      };
    }
    return <String, dynamic>{
      'enabled': true,
      'server_name': n.sni ?? n.server,
      if (n.allowInsecure) 'insecure': true,
      if (n.alpn.isNotEmpty) 'alpn': n.alpn,
      // TLS ClientHello fragmentation (sing-box 1.12+ outbound TLS option, keys
      // `fragment`/`fragment_fallback_delay` — the `tls_fragment` spelling is the
      // route-rule form, not this one). Splits the handshake so Iran's DPI can't
      // match the SNI in a single plaintext packet — the other half of the
      // anti-DPI story alongside the uTLS fingerprint, and the trick Xray-based
      // clients rely on. Not applied to Reality: its handshake already looks like
      // a real TLS session, so fragmenting it would only add latency.
      if (fragment && !n.isReality) ...<String, dynamic>{
        'fragment': true,
        'fragment_fallback_delay': '500ms',
      },
      if (n.isReality)
        'reality': <String, dynamic>{
          'enabled': true,
          'public_key': n.realityPublicKey,
          if (n.realityShortId != null && n.realityShortId!.isNotEmpty)
            'short_id': n.realityShortId,
        },
      'utls': <String, dynamic>{'enabled': true, 'fingerprint': fingerprint},
    };
  }

  /// The node with the SNI-block bypass applied when [SingboxRouteOptions
  /// .hardenTls] asks for it and the node is the kind it is for. Domain-
  /// addressed nodes and nodes that already carry their own profile from the
  /// link pass through unchanged.
  /// The `nova_fragment` stages for a hardened node.
  ///
  /// If the node carries an `fm` mask (a PattNG / cf-optimizor link), its stages
  /// are used verbatim, so the bytes match what that tool produces. Otherwise
  /// the field-tested default is used. When [packetStage] is false (Windows) the
  /// TCP-segment stage (packets other than the tlshello record split) is
  /// dropped, keeping only the record split.
  static List<Map<String, dynamic>> _novaFragmentStages(
      ProxyNode n, bool packetStage) {
    List<Map<String, dynamic>> stages;
    final String? fm = n.fragmentMask;
    if (fm != null && fm.isNotEmpty) {
      try {
        final Object? doc = jsonDecode(fm);
        final Object? tcp = doc is Map ? doc['tcp'] : null;
        stages = (tcp is List)
            ? tcp
                .whereType<Map>()
                .map((Map m) => (m['settings'] as Map?)?.cast<String, dynamic>())
                .whereType<Map<String, dynamic>>()
                .map(_fmStage)
                .toList()
            : _defaultNovaFragment;
      } catch (_) {
        stages = _defaultNovaFragment;
      }
    } else {
      stages = _defaultNovaFragment;
    }
    if (!packetStage) {
      // Keep only the TLS-record split (packets: tlshello).
      stages = stages
          .where((Map<String, dynamic> st) =>
              (st['packets'] as String?)?.toLowerCase() == 'tlshello')
          .toList();
    }
    return stages;
  }

  /// One Xray finalmask fragment stage, normalised to string fields (lengths,
  /// delays and maxSplit are strings in the links PattNG writes).
  static Map<String, dynamic> _fmStage(Map<String, dynamic> settings) {
    List<String> strs(Object? v) => v is List
        ? v.map((Object? e) => '$e').toList()
        : (v == null ? const <String>[] : <String>['$v']);
    return <String, dynamic>{
      if (settings['packets'] != null) 'packets': '${settings['packets']}',
      if (settings['lengths'] != null) 'lengths': strs(settings['lengths']),
      if (settings['delays'] != null) 'delays': strs(settings['delays']),
      if (settings['maxSplit'] != null) 'maxSplit': '${settings['maxSplit']}',
    };
  }

  /// The field-tested finalmask: ClientHello into TLS records of 5, 94, then 1
  /// byte, merged into one write; that write split into TCP segments of 109 then
  /// 1 byte, 1 ms apart, capped at 355.
  static const List<Map<String, dynamic>> _defaultNovaFragment =
      <Map<String, dynamic>>[
    <String, dynamic>{
      'packets': 'tlshello',
      'lengths': <String>['5', '94', '1'],
      'delays': <String>['0'],
      'maxSplit': '0',
    },
    <String, dynamic>{
      'packets': '1-1',
      'lengths': <String>['109', '1'],
      'delays': <String>['1'],
      'maxSplit': '355',
    },
  ];

  static ProxyNode _maybeHarden(ProxyNode n, SingboxRouteOptions o) =>
      (o.hardenTls && n.isCleanIpFronted)
          ? n.hardened(
              fingerprint: o.bypassFingerprint,
              cipherSuites: o.bypassCipherSuites,
              fragmentMask: o.bypassFragmentMask,
            )
          : n;

  /// The cipher suite names the sing-box core accepts, measured against the
  /// 1.13.13 binary: it looks names up in Go's secure list only, so anything in
  /// Go's insecure list ("unknown cipher_suite: TLS_ECDHE_ECDSA_WITH_AES_128_
  /// CBC_SHA256", which the PattNG recipe includes) is dropped here rather than
  /// handed to a core that refuses the whole outbound over it.
  static const Set<String> _coreCipherSuites = <String>{
    'TLS_AES_128_GCM_SHA256',
    'TLS_AES_256_GCM_SHA384',
    'TLS_CHACHA20_POLY1305_SHA256',
    'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
    'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256',
    'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384',
    'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384',
    'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256',
    'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256',
    'TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA',
    'TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA',
    'TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA',
    'TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA',
    'TLS_RSA_WITH_AES_128_GCM_SHA256',
    'TLS_RSA_WITH_AES_256_GCM_SHA384',
    'TLS_RSA_WITH_AES_128_CBC_SHA',
    'TLS_RSA_WITH_AES_256_CBC_SHA',
  };

  static Map<String, dynamic>? _transport(ProxyNode n) {
    switch (n.network) {
      case 'ws':
        return <String, dynamic>{
          'type': 'ws',
          'path': n.wsPath ?? '/',
          if (n.wsHost != null && n.wsHost!.isNotEmpty)
            'headers': <String, dynamic>{'Host': n.wsHost},
        };
      case 'grpc':
        return <String, dynamic>{
          'type': 'grpc',
          'service_name': n.grpcServiceName ?? '',
        };
      case 'http':
        // HTTP/2 transport. sing-box takes `host` as a list and needs TLS/ALPN
        // h2 (handled by the tls block). Previously this fell through to null,
        // so h2 nodes silently built as plain TCP and never connected.
        return <String, dynamic>{
          'type': 'http',
          if (n.wsHost != null && n.wsHost!.isNotEmpty)
            'host': <String>[n.wsHost!],
          'path': n.wsPath ?? '/',
        };
      case 'httpupgrade':
        return <String, dynamic>{
          'type': 'httpupgrade',
          if (n.wsHost != null && n.wsHost!.isNotEmpty) 'host': n.wsHost,
          'path': n.wsPath ?? '/',
        };
      default:
        return null;
    }
  }

  static Map<String, dynamic> _route(SingboxRouteOptions o, {bool blockQuic = true}) {
    final List<Map<String, dynamic>> rules = <Map<String, dynamic>>[
      // Sniff each connection's protocol and domain (TLS SNI, HTTP Host, DNS
      // question) so the domain-based rules below can match. This replaces the
      // inbound-level `sniff` field that sing-box 1.13 removed; the `sniff` rule
      // action is the supported form (valid on 1.11+). It must run first, before
      // the DNS hijack and domain rules that depend on the sniffed name.
      <String, dynamic>{'action': 'sniff'},
      // Hijack sniffed DNS to the DNS module. The old form routed to a 'dns'
      // outbound, which sing-box 1.13 removed; the 'hijack-dns' rule action is
      // the supported replacement (valid on 1.11+/1.12/1.13).
      <String, dynamic>{'protocol': 'dns', 'action': 'hijack-dns'},
      // Nova's own Cloudflare management calls (panel deploy, KV, etc.) must go
      // direct: routing them through the proxy fails because Cloudflare loop-
      // protects requests coming back through a CF-worker exit ("Failed host
      // lookup: api.cloudflare.com" during deploy).
      <String, dynamic>{'domain': _directHosts, 'outbound': 'direct'},
      // vless-over-WS/TLS (the Cloudflare Worker exit) carries TCP only, so QUIC
      // (HTTP/3 over UDP) can't be relayed and just times out — Instagram/
      // YouTube break while TCP apps like Telegram work. Block QUIC so those
      // apps fall back to TCP. But a real Hysteria2/TUIC exit carries UDP end to
      // end, so QUIC must pass through there (that's the whole speed win) — the
      // caller sets [blockQuic] false when any exit is UDP-native.
      if (blockQuic) <String, dynamic>{'protocol': 'quic', 'outbound': 'block'},
    ];
    final List<Map<String, dynamic>> ruleSets = <Map<String, dynamic>>[];

    // Lean (iOS) path: use BUNDLED (local) geosite rule-sets instead of the
    // remote ones the full path downloads — no startup fetch, and small enough
    // for the extension's memory budget. Domain-based only (geoip is skipped:
    // it can't match the fake IPs the lean DNS issues). Iran domains go direct
    // (faster, and off the worker), ads are blocked, everything else proxied.
    if (o.lean) {
      final List<Map<String, dynamic>> leanRuleSets = <Map<String, dynamic>>[];
      if (o.bypassLan && o.mode != SingboxMode.direct) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds && o.mode != SingboxMode.direct) {
        rules.add(<String, dynamic>{'rule_set': 'geosite-ads', 'outbound': 'block'});
        leanRuleSets.add(_localRuleSet('geosite-ads', kGeositeAdsFile));
      }
      if (o.bypassIran && o.mode == SingboxMode.rule) {
        // Any .ir domain goes direct by TLD suffix alone: an instant match that
        // needs no rule-set download, so every Iranian site keeps working (on the
        // user's real IP) even if the geosite-ir set can't load.
        rules.add(<String, dynamic>{'domain_suffix': '.ir', 'outbound': 'direct'});
        rules.add(<String, dynamic>{'rule_set': 'geosite-ir', 'outbound': 'direct'});
        leanRuleSets.add(_localRuleSet('geosite-ir', kGeositeIrFile));
      }
      return <String, dynamic>{
        'rules': rules,
        if (leanRuleSets.isNotEmpty) 'rule_set': leanRuleSets,
        'final': o.mode == SingboxMode.direct ? 'direct' : 'proxy',
        'auto_detect_interface': true,
        'default_domain_resolver': _defaultDomainResolver,
      };
    }

    // Adds the ad-block rule-set, local (bundled) or remote per [o.localRuleSets].
    void addAds() {
      rules.add(<String, dynamic>{'rule_set': 'geosite-ads', 'outbound': 'block'});
      ruleSets.add(o.localRuleSets
          ? _localRuleSet('geosite-ads', kGeositeAdsFile)
          : _remoteRuleSet('geosite-ads', _adsRuleSet));
    }

    if (o.mode == SingboxMode.rule) {
      if (o.bypassLan) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds) addAds();
      if (o.bypassIran) {
        // Any .ir domain goes direct by TLD suffix alone (real IP, bypass proxy):
        // an instant match with no rule-set download, so Iranian sites keep working
        // even if the geo rule-sets below fail to load. The rule-sets still add the
        // Iranian sites that live on non-.ir domains (e.g. .com).
        rules.add(<String, dynamic>{'domain_suffix': '.ir', 'outbound': 'direct'});
        if (o.localRuleSets) {
          // geoip-ir isn't bundled; bypass Iran by domain only (the geosite-ir
          // list covers Iranian sites) so nothing has to download at startup.
          rules.add(
              <String, dynamic>{'rule_set': 'geosite-ir', 'outbound': 'direct'});
          ruleSets.add(_localRuleSet('geosite-ir', kGeositeIrFile));
        } else {
          rules.add(<String, dynamic>{
            'rule_set': <String>['geoip-ir', 'geosite-ir'],
            'outbound': 'direct',
          });
          ruleSets.add(_remoteRuleSet('geoip-ir', _geoipIr));
          ruleSets.add(_remoteRuleSet('geosite-ir', _geositeIr));
        }
      }
    } else if (o.mode == SingboxMode.global) {
      if (o.bypassLan) {
        rules.add(<String, dynamic>{'ip_is_private': true, 'outbound': 'direct'});
      }
      if (o.blockAds) addAds();
    }

    final String finalOutbound =
        o.mode == SingboxMode.direct ? 'direct' : 'proxy';

    return <String, dynamic>{
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': finalOutbound,
      'auto_detect_interface': true,
      'default_domain_resolver': _defaultDomainResolver,
    };
  }

  /// How an outbound resolves its own server hostname (sing-box 1.12+).
  ///
  /// The DNS rules already send every proxy server's name to the `local`
  /// (direct) resolver, so this states the same intent where the 1.13 core now
  /// insists on it. Without it the CLI core refuses to start ("missing
  /// `route.default_domain_resolver` ... will be removed in sing-box 1.14.0"),
  /// and the NaiveProxy outbound refuses independently ("missing domain
  /// resolver for domain server address") because cronet does its own dialing.
  /// libbox on the phones only warned, which is why Android and iOS kept
  /// working; the desktop binary is the CLI and it does not. Every shipped core
  /// is 1.13, so this is safe everywhere.
  static const Map<String, dynamic> _defaultDomainResolver =
      <String, dynamic>{'server': 'local'};

  /// The hosts the remote rule-sets are fetched from. They resolve via the
  /// direct DNS (see [_dns]) so the download never waits on the proxy.
  static const List<String> _ruleSetHosts = <String>['raw.githubusercontent.com'];

  /// Nova's own Cloudflare management endpoints. Resolved via direct DNS and
  /// routed direct (see [_route]) so panel deploy / KV calls work while the
  /// tunnel is up instead of failing a host lookup.
  static const List<String> _directHosts = <String>[
    'api.cloudflare.com',
    'dash.cloudflare.com',
  ];

  /// Placeholder in local rule-set paths, swapped for the real App Group
  /// container path by the iOS host (NovaProxyHost) before the config is written,
  /// so the extension reads the bundled `.srs` files from a valid absolute path.
  static const String ruleSetBaseToken = '__NOVA_BASE__';

  static const String kGeositeIrFile = 'geosite-ir.srs';
  static const String kGeositeAdsFile = 'geosite-ads.srs';

  /// Bundled asset path -> filename the host writes into the container. The iOS
  /// proxy controller ships exactly these on the lean path so the local
  /// rule-sets below resolve. Domain-based (geosite) only: geoip can't match the
  /// fake IPs the lean DNS hands out, so a geoip rule-set would never fire.
  static const Map<String, String> leanRuleSetAssets = <String, String>{
    'assets/rulesets/geosite-ir.srs': kGeositeIrFile,
    'assets/rulesets/geosite-ads.srs': kGeositeAdsFile,
  };

  static Map<String, dynamic> _localRuleSet(String tag, String fileName) =>
      <String, dynamic>{
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': '$ruleSetBaseToken/$fileName',
      };

  static Map<String, dynamic> _remoteRuleSet(String tag, String url) =>
      <String, dynamic>{
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': url,
        // Download directly, not through `proxy`. On the iOS/Android TUN path
        // the proxy isn't ready while the core is still starting, so a proxied
        // rule-set fetch deadlocks service start and the tunnel hangs on
        // "Connecting". Direct + direct-DNS resolution is self-contained.
        'download_detour': 'direct',
      };

  /// The server/SNI/WS-host domains the proxy outbounds dial. These must resolve
  /// via the direct DNS so bringing the proxy up doesn't depend on a resolver
  /// that is itself reached through the proxy (the startup DNS loop). IP
  /// literals are skipped — they need no resolution.
  static List<String> _directDomains(List<ProxyNode> nodes) {
    final Set<String> out = <String>{};
    for (final ProxyNode n in nodes) {
      for (final String? d in <String?>[n.server, n.sni, n.wsHost]) {
        if (d != null && d.isNotEmpty && !_isIpLiteral(d)) out.add(d);
      }
    }
    return out.toList();
  }

  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true; // IPv6
    final List<String> parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((String p) {
      final int? v = int.tryParse(p);
      return v != null && v >= 0 && v <= 255;
    });
  }
}

/// The flow value sing-box will accept, or null for none.
///
/// Xray ships variants sing-box does not know, and an unrecognised flow is
/// FATAL to the core rather than ignored: one such server anywhere in a
/// subscription stops the core from starting, so the user loses every server,
/// not just that one. Two servers out of 1918 in the public free lists carry
/// `xtls-rprx-vision-udp443`, and each of them killed a whole 200-server batch
/// when measuring.
///
/// The `-udp443` suffix is a client-side Xray behaviour switch (whether UDP/443
/// goes through the proxy) and does not change what goes on the wire, so the
/// base flow is the faithful translation. Anything else unrecognised is dropped
/// rather than guessed at: a server that needs a flow Nova cannot speak will
/// fail on its own, without taking the rest of the list with it.
String? _singboxFlow(String? raw) {
  final String f = (raw ?? '').trim();
  if (f.isEmpty) return null;
  if (f == 'xtls-rprx-vision') return f;
  if (f.startsWith('xtls-rprx-vision')) return 'xtls-rprx-vision';
  return null;
}

/// uTLS fingerprints the sing-box core knows.
///
/// An unknown one is FATAL: the core refuses the whole config, so a single node
/// carrying an Xray-only value stops every other node in it from being dialled.
const Set<String> kSingboxFingerprints = <String>{
  'chrome', 'firefox', 'edge', 'safari', 'ios', 'android',
  'random', 'randomized', '360', 'qq',
};

/// A fingerprint the core will accept.
///
/// Xray's `fp=unsafe` means "no browser fingerprint, Go's own TLS with my
/// cipher list". Nova's SNI-block bypass emits exactly that, and for a plain
/// TLS node it is honoured by turning uTLS off entirely (see the hardened
/// branch above). Reality cannot do that: its handshake IS a forged uTLS
/// ClientHello, so it keeps uTLS on and the raw `unsafe` reached the core.
///
/// That combination is not rare. In the published free list, 88 of 200 nodes in
/// a measuring pool were Reality servers whose links carry `fp=unsafe`, and any
/// one of them made the core exit before it started, so the ping test spun for
/// ever and no server ever got a number.
///
/// Chrome is the substitute because it is what the node would have been given
/// with no fingerprint at all, and because for Reality the browser profile only
/// chooses which ClientHello to forge, not whether to forge one.
String _singboxFingerprint(String raw) {
  final String f = raw.trim().toLowerCase();
  return kSingboxFingerprints.contains(f) ? f : 'chrome';
}
