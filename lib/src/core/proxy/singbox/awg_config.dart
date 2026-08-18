import 'dart:convert';

/// A parsed AmneziaWG (or plain WireGuard) configuration.
///
/// AmneziaWG is WireGuard plus obfuscation: junk packets (Jc/Jmin/Jmax),
/// handshake junk (S1-S4) and magic headers (H1-H4, plus AWG 1.5/2.0 decoys
/// I1-I5) make the handshake unfingerprintable to DPI. The shipped Nova core
/// (hiddify `extended`, built `with_awg`) has a first-class `awg` endpoint, so
/// once parsed this maps 1:1 onto that endpoint. A config with none of the junk
/// fields is just plain WireGuard, which the same endpoint carries fine.
///
/// Parses the standard `awg-quick` / `wg-quick` `.conf` INI text (what Amnezia
/// QR codes and the Nova node emit). One `[Interface]` and one `[Peer]`.
class AwgConfig {
  AwgConfig({
    required this.privateKey,
    required this.address,
    required this.peer,
    this.dns = const <String>[],
    this.mtu,
    this.jc,
    this.jmin,
    this.jmax,
    this.s1,
    this.s2,
    this.s3,
    this.s4,
    this.h1,
    this.h2,
    this.h3,
    this.h4,
    this.i1,
    this.i2,
    this.i3,
    this.i4,
    this.i5,
  });

  final String privateKey;
  final List<String> address;
  final List<String> dns;
  final int? mtu;

  // Obfuscation params. Present => AmneziaWG; all null => plain WireGuard.
  final int? jc, jmin, jmax, s1, s2, s3, s4;
  final String? h1, h2, h3, h4, i1, i2, i3, i4, i5;

  final AwgPeer peer;

  /// True when any obfuscation field is set, i.e. this is AmneziaWG not plain WG.
  bool get isObfuscated =>
      jc != null ||
      jmin != null ||
      jmax != null ||
      s1 != null ||
      s2 != null ||
      s3 != null ||
      s4 != null ||
      h1 != null ||
      i1 != null;

  /// The endpoint host:port as `host:port` (for display / a share link).
  String get endpoint => '${peer.host}:${peer.port}';

  /// Parse `awg-quick` `.conf` INI text. Throws [FormatException] when the
  /// required WireGuard fields are missing. Keys are matched case-insensitively;
  /// list values (Address, DNS, AllowedIPs) split on commas.
  static AwgConfig parseConf(String text) {
    final Map<String, String> iface = <String, String>{};
    final Map<String, String> peer = <String, String>{};
    Map<String, String>? section;
    for (String raw in text.split('\n')) {
      final int hash = raw.indexOf('#');
      if (hash >= 0) raw = raw.substring(0, hash);
      final String line = raw.trim();
      if (line.isEmpty) continue;
      final String lower = line.toLowerCase();
      if (lower == '[interface]') {
        section = iface;
        continue;
      }
      if (lower == '[peer]') {
        section = peer;
        continue;
      }
      final int eq = line.indexOf('=');
      if (eq < 0 || section == null) continue;
      final String key = line.substring(0, eq).trim().toLowerCase();
      final String val = line.substring(eq + 1).trim();
      section[key] = val;
    }

    List<String> list(Map<String, String> m, String k) =>
        (m[k] ?? '').split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    int? intOf(Map<String, String> m, String k) =>
        m[k] == null ? null : int.tryParse(m[k]!.trim());
    String? strOf(Map<String, String> m, String k) =>
        (m[k] == null || m[k]!.trim().isEmpty) ? null : m[k]!.trim();

    final String? priv = strOf(iface, 'privatekey');
    final List<String> addr = list(iface, 'address');
    final String? pub = strOf(peer, 'publickey');
    final String? ep = strOf(peer, 'endpoint');
    if (priv == null || addr.isEmpty || pub == null || ep == null) {
      throw const FormatException(
          'not a valid WireGuard/AmneziaWG config (need PrivateKey, Address, PublicKey, Endpoint)');
    }

    final (String host, int port) = _splitHostPort(ep);

    return AwgConfig(
      privateKey: priv,
      address: addr,
      dns: list(iface, 'dns'),
      mtu: intOf(iface, 'mtu'),
      jc: intOf(iface, 'jc'),
      jmin: intOf(iface, 'jmin'),
      jmax: intOf(iface, 'jmax'),
      s1: intOf(iface, 's1'),
      s2: intOf(iface, 's2'),
      s3: intOf(iface, 's3'),
      s4: intOf(iface, 's4'),
      h1: strOf(iface, 'h1'),
      h2: strOf(iface, 'h2'),
      h3: strOf(iface, 'h3'),
      h4: strOf(iface, 'h4'),
      i1: strOf(iface, 'i1'),
      i2: strOf(iface, 'i2'),
      i3: strOf(iface, 'i3'),
      i4: strOf(iface, 'i4'),
      i5: strOf(iface, 'i5'),
      peer: AwgPeer(
        publicKey: pub,
        presharedKey: strOf(peer, 'presharedkey'),
        allowedIps: list(peer, 'allowedips').isEmpty
            ? const <String>['0.0.0.0/0', '::/0']
            : list(peer, 'allowedips'),
        host: host,
        port: port,
        keepalive: intOf(peer, 'persistentkeepalive'),
      ),
    );
  }

  /// True if [text] looks like a WireGuard/AmneziaWG `.conf` we can parse.
  static bool looksLikeConf(String text) {
    final String t = text.toLowerCase();
    return t.contains('[interface]') && t.contains('privatekey');
  }

  /// The sing-box endpoint object for this config. An obfuscated config emits an
  /// `awg` endpoint (junk params; needs a core built with AmneziaWG); a plain
  /// WireGuard config emits a `wireguard` endpoint, which the stock sing-box core
  /// supports. The peer's pre-shared-key field name also differs between the two
  /// (`preshared_key` for awg, `pre_shared_key` for wireguard). [tag] names it
  /// for routing.
  Map<String, dynamic> toEndpoint(String tag) {
    final bool obf = isObfuscated;
    final String pskKey = obf ? 'preshared_key' : 'pre_shared_key';
    final Map<String, dynamic> peerObj = <String, dynamic>{
      'public_key': peer.publicKey,
      'address': peer.host,
      'port': peer.port,
      'allowed_ips': peer.allowedIps,
      if (peer.presharedKey != null) pskKey: peer.presharedKey,
      'persistent_keepalive_interval': peer.keepalive ?? 25,
    };
    return <String, dynamic>{
      'type': obf ? 'awg' : 'wireguard',
      'tag': tag,
      'private_key': privateKey,
      'address': address,
      if (mtu != null) 'mtu': mtu,
      if (jc != null) 'jc': jc,
      if (jmin != null) 'jmin': jmin,
      if (jmax != null) 'jmax': jmax,
      if (s1 != null) 's1': s1,
      if (s2 != null) 's2': s2,
      if (s3 != null) 's3': s3,
      if (s4 != null) 's4': s4,
      if (h1 != null) 'h1': h1,
      if (h2 != null) 'h2': h2,
      if (h3 != null) 'h3': h3,
      if (h4 != null) 'h4': h4,
      if (i1 != null) 'i1': i1,
      if (i2 != null) 'i2': i2,
      if (i3 != null) 'i3': i3,
      if (i4 != null) 'i4': i4,
      if (i5 != null) 'i5': i5,
      'peers': <Map<String, dynamic>>[peerObj],
    };
  }

  /// The interface + junk fields flattened to a string map, for persisting the
  /// node's protocol-specific params without inventing a new column.
  Map<String, String> toParams() => <String, String>{
        'privateKey': privateKey,
        'address': address.join(','),
        if (dns.isNotEmpty) 'dns': dns.join(','),
        if (mtu != null) 'mtu': '$mtu',
        if (jc != null) 'jc': '$jc',
        if (jmin != null) 'jmin': '$jmin',
        if (jmax != null) 'jmax': '$jmax',
        if (s1 != null) 's1': '$s1',
        if (s2 != null) 's2': '$s2',
        if (s3 != null) 's3': '$s3',
        if (s4 != null) 's4': '$s4',
        if (h1 != null) 'h1': h1!,
        if (h2 != null) 'h2': h2!,
        if (h3 != null) 'h3': h3!,
        if (h4 != null) 'h4': h4!,
        if (i1 != null) 'i1': i1!,
        if (i2 != null) 'i2': i2!,
        if (i3 != null) 'i3': i3!,
        if (i4 != null) 'i4': i4!,
        if (i5 != null) 'i5': i5!,
        'publicKey': peer.publicKey,
        if (peer.presharedKey != null) 'presharedKey': peer.presharedKey!,
        'allowedIps': peer.allowedIps.join(','),
        'host': peer.host,
        'port': '${peer.port}',
        if (peer.keepalive != null) 'keepalive': '${peer.keepalive}',
      };

  /// Rebuild from the flattened param map produced by [toParams].
  static AwgConfig fromParams(Map<String, String> p) {
    List<String> list(String k, [List<String> dflt = const <String>[]]) =>
        (p[k] ?? '').split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList().isEmpty
            ? dflt
            : (p[k] ?? '').split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
    int? intOf(String k) => p[k] == null ? null : int.tryParse(p[k]!);
    return AwgConfig(
      privateKey: p['privateKey'] ?? '',
      address: list('address'),
      dns: list('dns'),
      mtu: intOf('mtu'),
      jc: intOf('jc'),
      jmin: intOf('jmin'),
      jmax: intOf('jmax'),
      s1: intOf('s1'),
      s2: intOf('s2'),
      s3: intOf('s3'),
      s4: intOf('s4'),
      h1: p['h1'],
      h2: p['h2'],
      h3: p['h3'],
      h4: p['h4'],
      i1: p['i1'],
      i2: p['i2'],
      i3: p['i3'],
      i4: p['i4'],
      i5: p['i5'],
      peer: AwgPeer(
        publicKey: p['publicKey'] ?? '',
        presharedKey: p['presharedKey'],
        allowedIps: list('allowedIps', const <String>['0.0.0.0/0', '::/0']),
        host: p['host'] ?? '',
        port: int.tryParse(p['port'] ?? '') ?? 51820,
        keepalive: intOf('keepalive'),
      ),
    );
  }

  @override
  String toString() => jsonEncode(toEndpoint('awg'));
}

class AwgPeer {
  AwgPeer({
    required this.publicKey,
    required this.allowedIps,
    required this.host,
    required this.port,
    this.presharedKey,
    this.keepalive,
  });

  final String publicKey;
  final String? presharedKey;
  final List<String> allowedIps;
  final String host;
  final int port;
  final int? keepalive;
}

/// The `Endpoint` host from a WireGuard/AmneziaWG `.conf`, or null if absent.
/// Used to resolve a domain endpoint to an IP before the core sees it (the
/// AmneziaWG core parses the endpoint with ParseAddr and rejects a hostname).
String? awgEndpointHost(String conf) {
  for (final String raw in conf.split('\n')) {
    final String line = raw.trim();
    final int eq = line.indexOf('=');
    if (eq < 0) continue;
    if (line.substring(0, eq).trim().toLowerCase() != 'endpoint') continue;
    final (String host, int _) = _splitHostPort(line.substring(eq + 1).trim());
    return host.isEmpty ? null : host;
  }
  return null;
}

/// Returns [conf] with the `Endpoint` line's host replaced by [ip] (port kept).
/// A no-op if there is no Endpoint line. IPv6 IPs are bracketed.
String rewriteAwgEndpointHost(String conf, String ip) {
  final String rendered = ip.contains(':') ? '[$ip]' : ip;
  final List<String> out = <String>[];
  for (final String raw in conf.split('\n')) {
    final String line = raw.trim();
    final int eq = line.indexOf('=');
    if (eq >= 0 &&
        line.substring(0, eq).trim().toLowerCase() == 'endpoint') {
      final (String _, int port) = _splitHostPort(line.substring(eq + 1).trim());
      out.add('Endpoint = $rendered:$port');
    } else {
      out.add(raw);
    }
  }
  return out.join('\n');
}

/// Split a WireGuard `Endpoint` into host + port, handling bracketed IPv6
/// (`[2001:db8::1]:51820`) as well as `host:port`.
(String, int) _splitHostPort(String ep) {
  final String s = ep.trim();
  if (s.startsWith('[')) {
    final int close = s.indexOf(']');
    final String host = s.substring(1, close);
    final int colon = s.indexOf(':', close);
    final int port = colon >= 0 ? int.tryParse(s.substring(colon + 1)) ?? 51820 : 51820;
    return (host, port);
  }
  final int colon = s.lastIndexOf(':');
  if (colon < 0) return (s, 51820);
  return (s.substring(0, colon), int.tryParse(s.substring(colon + 1)) ?? 51820);
}
