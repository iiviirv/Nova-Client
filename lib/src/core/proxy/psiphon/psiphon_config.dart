/// Configuration for the Psiphon engine, which Nova runs as its own process
/// (desktop, Android) or compiles into the core (iOS), the way MasterDNS is.
///
/// Why Nova carries Psiphon at all, from the tester in Iran:
///
///   "when it is tunnelled from inside aether it gains speed. the advantage is
///    that aether configs give an Iranian IP and a lot of things are blocked on
///    it, sanctioned. that way psiphon comes on top of it and opens it up."
///
/// WARP and Psiphon fail in opposite directions. WARP reaches out of Iran
/// quickly but its exit usually geolocates back to Iran, so sanctioned services
/// refuse it. Psiphon gives a foreign exit but is slow or blocked when dialled
/// from inside. Chained, each covers the other's weakness: WARP carries the
/// bytes, Psiphon decides where they come out.
library;

import 'dart:convert';

/// How Psiphon is dialled.
enum PsiphonMode {
  /// Psiphon reaches its own network directly. Used when WARP cannot be
  /// reached at all.
  direct,

  /// Psiphon dials out through a local SOCKS5 proxy, which in practice is a
  /// running Aether (WARP) tunnel. This is the shape the tester asked for.
  throughAether,
}

class PsiphonConfig {
  const PsiphonConfig({
    required this.socksPort,
    required this.dataDir,
    this.mode = PsiphonMode.direct,
    this.upstreamSocksPort,
    this.clientPlatform = 'nova',
  });

  /// The loopback port Psiphon serves SOCKS5 on, which sing-box forwards into.
  final int socksPort;

  /// Where Psiphon keeps its server list and state between runs. Psiphon needs
  /// somewhere writable it owns; it is not a cache that can be thrown away
  /// without cost, because a fresh directory means fetching the server list
  /// again before anything can connect.
  final String dataDir;

  final PsiphonMode mode;

  /// The Aether tunnel's SOCKS5 port, when [mode] is [PsiphonMode.throughAether].
  final int? upstreamSocksPort;

  final String clientPlatform;

  /// Psiphon's anonymous identifiers. Its network accepts these from clients
  /// that are not one of its own distribution channels, which is what Nova is.
  static const String propagationChannelId = 'FFFFFFFFFFFFFFFF';
  static const String sponsorId = 'FFFFFFFFFFFFFFFF';

  /// Where the signed server list lives, and the key that signs it. Psiphon
  /// verifies the signature itself; the list is useless to an attacker who
  /// cannot sign it.
  static const String serverListUrl =
      'https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed';
  static const String serverListSignatureKey =
      'MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH'
      '5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5'
      'OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42Kcot'
      'LFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6'
      '/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7G'
      'stZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1O'
      'geF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8'
      'u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz'
      '31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xal'
      'KxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=';

  /// Everything Psiphon can dial when it owns its own sockets, including the
  /// QUIC-based protocols.
  static const List<String> directProtocols = <String>[
    'SSH',
    'OSSH',
    'TLS-OSSH',
    'UNFRONTED-MEEK-OSSH',
    'UNFRONTED-MEEK-HTTPS-OSSH',
    'UNFRONTED-MEEK-SESSION-TICKET-OSSH',
    'QUIC-OSSH',
    'SHADOWSOCKS-OSSH',
    'FRONTED-MEEK-OSSH',
    'FRONTED-MEEK-CDN-OSSH',
    'FRONTED-MEEK-HTTP-OSSH',
    'FRONTED-MEEK-CDN-HTTP-OSSH',
    'FRONTED-MEEK-QUIC-OSSH',
    'FRONTED-MEEK-CDN-QUIC-OSSH',
  ];

  /// The same list with every QUIC protocol removed.
  ///
  /// A SOCKS5 upstream carries TCP. QUIC is UDP, so a QUIC-based Psiphon
  /// protocol cannot travel through the Aether tunnel at all: it would dial,
  /// fail, and burn an attempt that a working protocol could have used. This
  /// is the same restriction the Aether core applies to its own chained mode.
  static List<String> get chainedProtocols => directProtocols
      .where((String p) => !p.contains('QUIC'))
      .toList(growable: false);

  /// True when the configuration is internally consistent. A chained config
  /// without an upstream port would silently dial direct, which is the one
  /// outcome the user did not ask for: an Iranian exit and the sanctions
  /// blocks that come with it.
  String? get problem {
    if (socksPort <= 0 || socksPort > 65535) {
      return 'The local proxy port must be between 1 and 65535.';
    }
    if (mode == PsiphonMode.throughAether) {
      final int? up = upstreamSocksPort;
      if (up == null || up <= 0 || up > 65535) {
        return 'Running Psiphon through Aether needs the tunnel\'s local port.';
      }
      if (up == socksPort) {
        return 'Psiphon cannot use its own port as its way out.';
      }
    }
    if (dataDir.trim().isEmpty) {
      return 'Psiphon needs a writable directory of its own.';
    }
    return null;
  }

  /// The JSON the engine reads. Field names are Psiphon's own and are
  /// case-sensitive.
  Map<String, Object?> engineJson() {
    final bool chained = mode == PsiphonMode.throughAether;
    return <String, Object?>{
      'PropagationChannelId': propagationChannelId,
      'SponsorId': sponsorId,
      'ClientPlatform': clientPlatform,
      'ClientVersion': '1',
      // The URL is carried base64-encoded inside the object, which is how
      // Psiphon expects it rather than as a plain string.
      'RemoteServerListURLs': <Map<String, String>>[
        <String, String>{'URL': base64.encode(utf8.encode(serverListUrl))},
      ],
      'RemoteServerListSignaturePublicKey': serverListSignatureKey,
      'DataRootDirectory': dataDir,
      'LocalSocksProxyPort': socksPort,
      // Nova serves its own HTTP proxy through sing-box, so Psiphon's is left
      // off rather than opening a second listener nobody uses.
      'LocalHttpProxyPort': 0,
      'LimitTunnelProtocols': chained ? chainedProtocols : directProtocols,
      // Psiphon's in-proxy mode turns the client into a relay for other people.
      // Nova does not opt its users into carrying strangers' traffic, on a
      // phone, in Iran, without asking. Both probabilities are held at zero.
      'InproxyTunnelProtocolPreferProbability': 0.0,
      'InproxyTunnelProtocolSelectionProbability': 0.0,
      if (chained)
        'UpstreamProxyURL': 'socks5://127.0.0.1:$upstreamSocksPort',
    };
  }

  /// How a Psiphon profile is stored.
  ///
  /// Only the mode is persisted. The local port and the state directory are
  /// decided at connect time, and writing a port into a saved profile would
  /// mean a profile that stops working when that port is taken.
  static const String scheme = 'psiphon';

  /// [viaAetherLink] is the `aether://` config the tunnel rides on, carried
  /// inside the link rather than looked up elsewhere.
  ///
  /// Nova has exactly one active profile, so "through Aether" cannot mean an
  /// Aether profile the user connected separately: that cannot exist at the
  /// same time as this one. The Psiphon profile brings the tunnel up itself,
  /// which means it has to know which gateway and settings to use. Keeping
  /// that inside the link makes the profile self-contained, re-shareable, and
  /// independent of whatever else is in the user's list.
  static String linkFor(PsiphonMode mode, {String? viaAetherLink}) {
    if (mode != PsiphonMode.throughAether) return '$scheme://direct';
    final String? via = viaAetherLink?.trim();
    if (via == null || via.isEmpty) return '$scheme://aether';
    return '$scheme://aether?via=${Uri.encodeQueryComponent(via)}';
  }

  /// The `aether://` config a chained link rides on, or null when it carries
  /// none. A chained profile without one cannot bring a tunnel up.
  static String? aetherLinkFrom(String link) {
    final Uri? u = Uri.tryParse(link.trim());
    if (u == null || u.scheme.toLowerCase() != scheme) return null;
    final String? via = u.queryParameters['via'];
    if (via == null || via.trim().isEmpty) return null;
    return via.trim();
  }

  /// The mode a stored link asks for, or null when the link is not one of ours.
  ///
  /// An unrecognised host is read as direct rather than refused. A profile that
  /// will not open at all is worse than one that opens in the safer of the two
  /// modes, and direct is the one that works without a tunnel already running.
  static PsiphonMode? modeFromLink(String link) {
    final Uri? u = Uri.tryParse(link.trim());
    if (u == null || u.scheme.toLowerCase() != scheme) return null;
    final String where = (u.host.isNotEmpty ? u.host : u.path.replaceAll('/', ''))
        .toLowerCase();
    return where == 'aether' ? PsiphonMode.throughAether : PsiphonMode.direct;
  }

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(engineJson());
}
