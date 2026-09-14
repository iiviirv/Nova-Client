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

  /// The query half of an `aether://` link, in the shape other clients already
  /// write. Kept byte-compatible on purpose: a config shared out of Nova has to
  /// import into them, and theirs into Nova, or sharing is only half a feature.
  ///
  /// The forced gateway is NOT here. It travels as the link's authority
  /// (`aether://ip:port?...`), which is where the other implementation puts it.
  /// Nova-only extras are emitted only when set, so a default config produces
  /// exactly the same string they would write.
  String toQuery() {
    final List<String> p = <String>['protocol=${mode.name}'];
    p.add('scan=${scan.name}');
    if (noize != null) p.add('noize=${noize!.name}');
    p.add('ip=${ip.name}');
    if (mode == AetherMode.masque) p.add('transport=${transport.name}');
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

  /// Reads the query half back. Unknown or misspelled values fall back to the
  /// default instead of reaching the binary, which would refuse to start.
  ///
  /// [peer] comes from the link's authority, not the query.
  static AetherOptions fromQuery(String? s, {String? peer}) {
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
      // 'protocol' is the key the other clients write; 'mode' is accepted too
      // because Nova's own first cut used it before the real format was known.
      mode: pick(AetherMode.values, q['protocol'] ?? q['mode'], AetherMode.masque),
      transport:
          pick(AetherTransport.values, q['transport'], AetherTransport.h3),
      ip: pick(AetherIpMode.values, q['ip'], AetherIpMode.v4),
      scan: pick(AetherScan.values, q['scan'], AetherScan.balanced),
      noize: q['noize'] == null
          ? null
          : pick(AetherNoize.values, q['noize'], AetherNoize.firewall),
      peer: nonEmpty(peer) ?? nonEmpty(q['peer']),
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

/// One Aether config: its settings, its optional forced gateway, and its name.
class AetherConfig {
  const AetherConfig({required this.options, this.name = 'Aether'});

  final AetherOptions options;
  final String name;

  /// The forced gateway, or null when the scan should find one.
  String? get gateway => options.peer;

  /// Writes the `aether://` link other clients read.
  String toLink() {
    final String auth = (options.peer ?? '');
    final String frag = name.isEmpty ? '' : '#${Uri.encodeComponent(name)}';
    return 'aether://$auth?${options.toQuery()}$frag';
  }

  /// Reads an `aether://` link. Returns null for anything else, so callers can
  /// try the other parsers in turn.
  static AetherConfig? parse(String input) {
    final String s = input.trim();
    if (!s.toLowerCase().startsWith('aether://')) return null;
    String rest = s.substring('aether://'.length);

    String name = '';
    final int hash = rest.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    String query = '';
    final int q = rest.indexOf('?');
    if (q >= 0) {
      query = rest.substring(q + 1);
      rest = rest.substring(0, q);
    }
    // What is left is the authority: the forced gateway, empty for a config
    // that scans (gool links are written `aether://?...` with nothing here).
    final String peer = rest.trim();
    return AetherConfig(
      options: AetherOptions.fromQuery(query, peer: peer.isEmpty ? null : peer),
      name: name.isEmpty ? 'Aether' : name,
    );
  }
}
