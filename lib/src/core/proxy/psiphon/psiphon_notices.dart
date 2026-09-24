import 'dart:convert';

/// Reads the engine's notice stream.
///
/// Psiphon writes one JSON object per line to stdout. Two things are wanted
/// from it: knowing when a tunnel is actually up, and putting something in
/// Nova's log without putting an address there.
///
/// Readiness cannot be taken from the local port. Psiphon opens its SOCKS
/// listener straight away, before any tunnel exists, so a port check would
/// report success while nothing could yet reach the internet. That is the same
/// mistake, in a different place, as the one that made a dead WARP gateway look
/// healthy. The honest signal is the `Tunnels` notice with a count above zero,
/// which is what the engine emits once traffic can flow.
abstract final class PsiphonNotices {
  /// Notice types worth showing a user. Everything else is engine chatter.
  static const Set<String> _interesting = <String>{
    'Tunnels',
    'ListeningSocksProxyPort',
    'ConnectingServer',
    'ActiveTunnel',
    'CandidateServers',
    'Info',
    'Warning',
    'Error',
    'Alert',
  };

  /// Addresses, in a log a user is invited to paste in public.
  ///
  /// Nova already shipped a release that wrote the user's own address into that
  /// log. The engine writes other people's: `rejecting in-proxy from country %s
  /// (IP: %s)` is a peer's address, and server candidates carry theirs. Nova
  /// does not relay for strangers, so that particular line should never fire,
  /// but a log guard that depends on a setting staying off is not a guard.
  static final RegExp _ipv4 = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');
  static final RegExp _ipv6 =
      RegExp(r'\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b');

  /// Parses one line. Returns null when the line is not a notice, which the
  /// engine does emit: a crash writes a Go panic here, not JSON.
  static Map<String, Object?>? parse(String line) {
    final String t = line.trim();
    if (!t.startsWith('{')) return null;
    try {
      final Object? v = jsonDecode(t);
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// True once the engine reports at least one live tunnel.
  ///
  /// A `Tunnels` notice with count zero means the opposite: a tunnel that was
  /// up has gone. Treating any `Tunnels` notice as readiness would call a
  /// disconnection a connection.
  static bool tunnelIsUp(String line) {
    final Map<String, Object?>? n = parse(line);
    if (n == null || n['noticeType'] != 'Tunnels') return false;
    final Object? data = n['data'];
    if (data is! Map) return false;
    final Object? count = data['count'];
    return count is num && count > 0;
  }

  /// A line safe to put in the user's log, or null if it is not worth showing.
  static String? forLog(String line) {
    final Map<String, Object?>? n = parse(line);
    if (n == null) {
      // Not JSON: a panic or a loader error. Worth keeping, still scrubbed.
      final String t = line.trim();
      return t.isEmpty ? null : scrub(t);
    }
    final Object? type = n['noticeType'];
    if (type is! String || !_interesting.contains(type)) return null;
    final Object? data = n['data'];
    final String detail = data == null ? '' : ' ${jsonEncode(data)}';
    return scrub('$type$detail');
  }

  /// Replaces anything that looks like an address.
  static String scrub(String text) => text
      .replaceAll(_ipv6, '[address removed]')
      .replaceAll(_ipv4, '[address removed]');
}
