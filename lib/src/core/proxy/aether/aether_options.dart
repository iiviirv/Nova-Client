/// The settings of one Aether config, and the command line they become.
///
/// Aether is a separate process that opens a WARP tunnel and serves it as a
/// local SOCKS5 proxy; sing-box then bridges into that port, the same two-core
/// shape the Xray/xhttp path already uses. So an Aether "server" is not an
/// address to dial, it is a set of choices about how the tunnel is built. That
/// is what this holds.
///
/// Every value is validated against what the binary actually accepts, and an
/// unrecognised one falls back to the default rather than being passed through.
/// This is deliberate: an unknown flag value makes the process exit at startup,
/// and the app would show a tunnel that never comes up with nothing on screen
/// to explain it. The same mistake with a uTLS fingerprint once stopped every
/// node in a measuring pool from being dialled.
library;

/// How the tunnel is carried.
enum AetherMode {
  /// MASQUE, over HTTP/3 (QUIC) or HTTP/2 (TCP). The default.
  masque,

  /// Classic WireGuard to a WARP endpoint.
  wg,

  /// WARP inside WARP: a WireGuard tunnel carried inside another one.
  gool,
}

/// Which MASQUE transport to use. Ignored for [AetherMode.wg] and
/// [AetherMode.gool], which are not carried over HTTP at all.
enum AetherTransport { h3, h2 }

/// Which address family the scan and the tunnel use.
enum AetherIpMode { v4, v6, both }

/// How hard to look for a reachable gateway.
enum AetherScan { turbo, balanced, thorough, stealth, ironclad }

/// The obfuscation profile applied to the handshake.
enum AetherNoize { off, light, firewall, balanced, gfw, aggressive }

class AetherOptions {
  const AetherOptions({
    this.mode = AetherMode.masque,
    this.transport = AetherTransport.h3,
    this.ip = AetherIpMode.v4,
    this.scan = AetherScan.balanced,
    this.noize,
    this.peer,
    this.wiwOuter,
    this.wiwInner,
    this.fragment = false,
    this.dns,
  });

  final AetherMode mode;
  final AetherTransport transport;
  final AetherIpMode ip;
  final AetherScan scan;

  /// Null means "let the binary pick": it defaults to `firewall` for MASQUE and
  /// `balanced` for the WireGuard modes, and those defaults are its business,
  /// not ours to duplicate and drift from.
  final AetherNoize? noize;

  /// Force a gateway instead of scanning, as `ip:port`.
  final String? peer;

  /// WARP-in-WARP hops. The port is required on each, because which port gets
  /// through is exactly what differs between networks.
  final String? wiwOuter;
  final String? wiwInner;

  /// Fragment the TLS ClientHello. Only meaningful on the HTTP/2 transport.
  final bool fragment;

  /// Resolvers used inside the tunnel.
  final String? dns;

  /// True when this config carries traffic over QUIC, which costs noticeably
  /// more CPU than the HTTP/2 transport. Measured 2026-09-10: 0.66 CPU-seconds
  /// per 20 MB against 0.37 for HTTP/2, on hardware far faster than the phones
  /// this has to run on. The device tier decides the default elsewhere; this
  /// just answers the question.
  bool get isQuic => mode == AetherMode.masque && transport == AetherTransport.h3;

  /// The command-line arguments for this config, excluding `--bind`, which is
  /// the caller's to choose because it owns the port.
  List<String> toCliArgs() {
    final List<String> a = <String>[
      switch (mode) {
        AetherMode.masque => '--masque',
        AetherMode.wg => '--wg',
        AetherMode.gool => '--gool',
      },
      '--scan',
      scan.name,
      switch (ip) {
        AetherIpMode.v4 => '-4',
        AetherIpMode.v6 => '-6',
        AetherIpMode.both => '--dual',
      },
    ];
    if (mode == AetherMode.masque && transport == AetherTransport.h2) {
      a.add('--h2');
      // The binary rejects --fragment outside the HTTP/2 transport, so it is
      // gated here rather than trusted to the caller.
      if (fragment) a.add('--fragment');
    }
    if (noize != null) a..add('--noize')..add(noize!.name);
    if (peer != null && peer!.isNotEmpty) a..add('--peer')..add(peer!);
    if (wiwOuter != null && wiwOuter!.isNotEmpty) {
      a..add('--wiw-outer')..add(wiwOuter!);
    }
    if (wiwInner != null && wiwInner!.isNotEmpty) {
      a..add('--wiw-inner')..add(wiwInner!);
    }
    if (dns != null && dns!.isNotEmpty) a..add('--dns')..add(dns!);
    return a;
  }

  /// The compact form stored on a node and carried in a share link.
  String encode() {
    final List<String> p = <String>['mode=${mode.name}'];
    if (mode == AetherMode.masque) p.add('transport=${transport.name}');
    p.add('ip=${ip.name}');
    p.add('scan=${scan.name}');
    if (noize != null) p.add('noize=${noize!.name}');
    if (peer != null && peer!.isNotEmpty) p.add('peer=${Uri.encodeComponent(peer!)}');
    if (wiwOuter != null && wiwOuter!.isNotEmpty) {
      p.add('outer=${Uri.encodeComponent(wiwOuter!)}');
    }
    if (wiwInner != null && wiwInner!.isNotEmpty) {
      p.add('inner=${Uri.encodeComponent(wiwInner!)}');
    }
    if (fragment) p.add('fragment=1');
    if (dns != null && dns!.isNotEmpty) p.add('dns=${Uri.encodeComponent(dns!)}');
    return p.join('&');
  }

  /// Reads [encode]'s form back. Unknown or misspelled values fall back to the
  /// default instead of reaching the binary, which would refuse to start.
  static AetherOptions decode(String? s) {
    final Map<String, String> q = <String, String>{};
    for (final String pair in (s ?? '').split('&')) {
      final int i = pair.indexOf('=');
      if (i <= 0) continue;
      q[pair.substring(0, i).toLowerCase()] =
          Uri.decodeComponent(pair.substring(i + 1));
    }
    T pick<T extends Enum>(List<T> values, String? raw, T fallback) {
      if (raw == null) return fallback;
      final String v = raw.trim().toLowerCase();
      for (final T e in values) {
        if (e.name == v) return e;
      }
      return fallback;
    }
    String? nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;
    return AetherOptions(
      mode: pick(AetherMode.values, q['mode'], AetherMode.masque),
      transport:
          pick(AetherTransport.values, q['transport'], AetherTransport.h3),
      ip: pick(AetherIpMode.values, q['ip'], AetherIpMode.v4),
      scan: pick(AetherScan.values, q['scan'], AetherScan.balanced),
      noize: q['noize'] == null
          ? null
          : pick(AetherNoize.values, q['noize'], AetherNoize.firewall),
      peer: nonEmpty(q['peer']),
      wiwOuter: nonEmpty(q['outer']),
      wiwInner: nonEmpty(q['inner']),
      fragment: q['fragment'] == '1' || q['fragment'] == 'true',
      dns: nonEmpty(q['dns']),
    );
  }

  AetherOptions copyWith({
    AetherMode? mode,
    AetherTransport? transport,
    AetherIpMode? ip,
    AetherScan? scan,
    AetherNoize? noize,
    String? peer,
    String? wiwOuter,
    String? wiwInner,
    bool? fragment,
    String? dns,
  }) =>
      AetherOptions(
        mode: mode ?? this.mode,
        transport: transport ?? this.transport,
        ip: ip ?? this.ip,
        scan: scan ?? this.scan,
        noize: noize ?? this.noize,
        peer: peer ?? this.peer,
        wiwOuter: wiwOuter ?? this.wiwOuter,
        wiwInner: wiwInner ?? this.wiwInner,
        fragment: fragment ?? this.fragment,
        dns: dns ?? this.dns,
      );
}
