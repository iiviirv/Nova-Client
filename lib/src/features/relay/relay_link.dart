import 'dart:convert';

/// A shareable, self-contained relay setup: everything a user needs to turn on
/// the Google relay (and, if set, the full tunnel) in one scan or paste.
///
/// Encoded as `nova-relay://<base64url(json)>` so an admin can export it from
/// the panel once and hand it out through a channel that still works when the
/// panel's own domain is blocked (a Telegram bot, a pasted string, a QR). The
/// client decodes it and fills the relay screen, no hand-typing of URLs/keys.
class RelayLinkData {
  const RelayLinkData({
    required this.execUrl,
    this.authKey = '',
    this.allowInsecure = false,
    this.frontEnabled = false,
    this.frontSni = '',
    this.frontIp = '',
    this.tunnelUrl = '',
    this.tunnelKey = '',
    this.tunnelPort,
    this.name = '',
  });

  final String execUrl;
  final String authKey;
  final bool allowInsecure;
  final bool frontEnabled;
  final String frontSni;
  final String frontIp;

  /// Optional full-tunnel exit shipped in the same link.
  final String tunnelUrl;
  final String tunnelKey;
  final int? tunnelPort;

  /// Optional label the admin gave this setup (shown on import).
  final String name;

  bool get hasTunnel => tunnelUrl.trim().isNotEmpty;

  /// The compact JSON map (short keys keep the link/QR small).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'u': execUrl,
        if (authKey.isNotEmpty) 'k': authKey,
        if (allowInsecure) 'i': 1,
        if (frontEnabled) 'f': 1,
        if (frontSni.isNotEmpty) 'fs': frontSni,
        if (frontIp.isNotEmpty) 'fi': frontIp,
        if (tunnelUrl.isNotEmpty) 'tu': tunnelUrl,
        if (tunnelKey.isNotEmpty) 'tk': tunnelKey,
        if (tunnelPort != null) 'tp': tunnelPort,
        if (name.isNotEmpty) 'n': name,
      };

  static RelayLinkData fromJson(Map<String, dynamic> j) => RelayLinkData(
        execUrl: (j['u'] as String?) ?? '',
        authKey: (j['k'] as String?) ?? '',
        allowInsecure: j['i'] == 1 || j['i'] == true,
        frontEnabled: j['f'] == 1 || j['f'] == true,
        frontSni: (j['fs'] as String?) ?? '',
        frontIp: (j['fi'] as String?) ?? '',
        tunnelUrl: (j['tu'] as String?) ?? '',
        tunnelKey: (j['tk'] as String?) ?? '',
        tunnelPort: (j['tp'] as num?)?.toInt(),
        name: (j['n'] as String?) ?? '',
      );

  static const String scheme = 'nova-relay://';

  /// `nova-relay://<base64url(json)>`.
  String encode() {
    final String b64 = base64Url
        .encode(utf8.encode(jsonEncode(toJson())))
        .replaceAll('=', '');
    return '$scheme$b64';
  }

  /// True if [text] looks like a relay link.
  static bool looksLike(String text) =>
      text.trim().toLowerCase().startsWith(scheme);

  /// Decode a `nova-relay://` link, or null if it is malformed / not one.
  static RelayLinkData? decode(String link) {
    final String t = link.trim();
    if (!looksLike(t)) return null;
    try {
      String b64 = t.substring(scheme.length);
      final int mod = b64.length % 4;
      if (mod != 0) b64 = b64.padRight(b64.length + (4 - mod), '=');
      final Map<String, dynamic> j =
          jsonDecode(utf8.decode(base64Url.decode(b64))) as Map<String, dynamic>;
      final RelayLinkData d = fromJson(j);
      if (d.execUrl.trim().isEmpty) return null;
      return d;
    } catch (_) {
      return null;
    }
  }
}
