import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Reading the `ech=` value out of a name's HTTPS record, over whichever
/// resolver was asked for.
///
/// Nova used to speak only DNS-over-HTTPS here. That was fine while the
/// resolver was Nova's own, but the ECH lookup is now editable in the form
/// other clients use, and that form names a transport: `udp://1.0.0.1` is a
/// request for UDP, not an invitation to use something else. Accepting the
/// text and quietly doing DoH anyway would be a setting that lies.
///
/// So this is a small DNS client: build a query for type 65, send it over UDP,
/// TCP or DoH, and pull SvcParam 5 out of the answer. Only as much of the
/// protocol as that needs, and no caching, which belongs to the caller.
abstract final class DnsHttpsRecord {
  /// RR type HTTPS.
  static const int kTypeHttps = 65;

  /// SvcParamKey `ech`.
  static const int kParamEch = 5;

  /// The `ech=` value for [domain] from [resolver], or null if there is none.
  static Future<String?> lookup(
    String domain,
    String resolver, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final String r = resolver.trim();
    final String lower = r.toLowerCase();
    try {
      if (lower.startsWith('https://')) {
        return await _overDoh(domain, r, timeout);
      }
      if (lower.startsWith('udp://')) {
        return await _overUdp(domain, r.substring(6), timeout);
      }
      if (lower.startsWith('tcp://')) {
        return await _overTcp(domain, r.substring(6), timeout);
      }
      return null;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// `host[:port]` split, defaulting to 53. An IPv6 literal is bracketed.
  static (String host, int port) _hostPort(String s, int fallbackPort) {
    String t = s.trim();
    if (t.startsWith('[')) {
      final int close = t.indexOf(']');
      if (close > 0) {
        final String h = t.substring(1, close);
        final String rest = t.substring(close + 1);
        return (h, rest.startsWith(':') ? int.tryParse(rest.substring(1)) ?? fallbackPort : fallbackPort);
      }
    }
    // More than one colon and no brackets: a bare IPv6 address, no port.
    if (':'.allMatches(t).length > 1) return (t, fallbackPort);
    final int c = t.lastIndexOf(':');
    if (c < 0) return (t, fallbackPort);
    return (t.substring(0, c), int.tryParse(t.substring(c + 1)) ?? fallbackPort);
  }

  static Future<String?> _overDoh(
      String domain, String url, Duration timeout) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final Uri u = Uri.parse(url).replace(queryParameters: <String, String>{
        'name': domain,
        'type': 'HTTPS',
      });
      final HttpClientRequest req = await client.getUrl(u);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final HttpClientResponse res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;
      return parseJsonAnswer(await res.transform(utf8.decoder).join());
    } finally {
      client.close(force: true);
    }
  }

  static Future<String?> _overUdp(
      String domain, String hostPort, Duration timeout) async {
    final (String host, int port) = _hostPort(hostPort, 53);
    final List<InternetAddress> addrs = await InternetAddress.lookup(host)
        .timeout(timeout, onTimeout: () => <InternetAddress>[]);
    if (addrs.isEmpty) return null;
    final RawDatagramSocket sock = await RawDatagramSocket.bind(
        addrs.first.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0);
    try {
      final Uint8List query = buildQuery(domain);
      sock.send(query, addrs.first, port);
      final Completer<Uint8List?> done = Completer<Uint8List?>();
      final StreamSubscription<RawSocketEvent> sub =
          sock.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = sock.receive();
        if (d != null && !done.isCompleted) {
          done.complete(Uint8List.fromList(d.data));
        }
      });
      try {
        final Uint8List? reply =
            await done.future.timeout(timeout, onTimeout: () => null);
        return reply == null ? null : parseWireAnswer(reply);
      } finally {
        await sub.cancel();
      }
    } finally {
      sock.close();
    }
  }

  static Future<String?> _overTcp(
      String domain, String hostPort, Duration timeout) async {
    final (String host, int port) = _hostPort(hostPort, 53);
    final Socket sock =
        await Socket.connect(host, port, timeout: timeout);
    try {
      final Uint8List q = buildQuery(domain);
      // DNS over TCP prefixes the message with its length.
      sock.add(<int>[(q.length >> 8) & 0xFF, q.length & 0xFF, ...q]);
      await sock.flush();
      final List<int> buf = <int>[];
      await for (final List<int> chunk in sock.timeout(timeout)) {
        buf.addAll(chunk);
        if (buf.length >= 2) {
          final int want = (buf[0] << 8) | buf[1];
          if (buf.length >= 2 + want) {
            return parseWireAnswer(Uint8List.fromList(buf.sublist(2, 2 + want)));
          }
        }
      }
      return null;
    } finally {
      sock.destroy();
    }
  }

  /// A minimal query for [domain] type HTTPS, with recursion desired.
  static Uint8List buildQuery(String domain, {int? id}) {
    final List<int> out = <int>[];
    final int qid = id ?? Random().nextInt(0x10000);
    out.addAll(<int>[(qid >> 8) & 0xFF, qid & 0xFF]);
    out.addAll(<int>[0x01, 0x00]); // recursion desired
    out.addAll(<int>[0x00, 0x01]); // one question
    out.addAll(<int>[0, 0, 0, 0, 0, 0]); // no answers, authority, additional
    for (final String label in domain.split('.')) {
      if (label.isEmpty) continue;
      final List<int> b = utf8.encode(label);
      if (b.length > 63) throw const FormatException('DNS label too long');
      out.add(b.length);
      out.addAll(b);
    }
    out.add(0); // root
    out.addAll(<int>[(kTypeHttps >> 8) & 0xFF, kTypeHttps & 0xFF]);
    out.addAll(<int>[0x00, 0x01]); // class IN
    return Uint8List.fromList(out);
  }

  /// The `ech=` value from a wire-format answer, or null.
  static String? parseWireAnswer(Uint8List msg) {
    try {
      if (msg.length < 12) return null;
      final int qd = (msg[4] << 8) | msg[5];
      final int an = (msg[6] << 8) | msg[7];
      if (an == 0) return null;
      int i = 12;
      for (int q = 0; q < qd; q++) {
        i = _skipName(msg, i);
        i += 4; // type + class
      }
      for (int a = 0; a < an && i < msg.length; a++) {
        i = _skipName(msg, i);
        if (i + 10 > msg.length) return null;
        final int type = (msg[i] << 8) | msg[i + 1];
        final int len = (msg[i + 8] << 8) | msg[i + 9];
        final int data = i + 10;
        if (data + len > msg.length) return null;
        if (type == kTypeHttps) {
          final String? ech = _echFromSvcb(msg, data, len);
          if (ech != null) return ech;
        }
        i = data + len;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// SvcParam 5 out of an HTTPS record body, base64 encoded as the text form
  /// and the config file both want it.
  static String? _echFromSvcb(Uint8List msg, int start, int len) {
    int i = start;
    final int end = start + len;
    if (i + 2 > end) return null;
    i += 2; // priority
    i = _skipName(msg, i); // target
    while (i + 4 <= end) {
      final int key = (msg[i] << 8) | msg[i + 1];
      final int vlen = (msg[i + 2] << 8) | msg[i + 3];
      final int v = i + 4;
      if (v + vlen > end) return null;
      if (key == kParamEch) {
        return base64.encode(msg.sublist(v, v + vlen));
      }
      i = v + vlen;
    }
    return null;
  }

  /// Past a name, following a compression pointer if there is one.
  static int _skipName(Uint8List msg, int i) {
    while (i < msg.length) {
      final int n = msg[i];
      if (n == 0) return i + 1;
      if ((n & 0xC0) == 0xC0) return i + 2; // pointer ends the name
      i += 1 + n;
    }
    return i;
  }

  /// The `ech=` value in a DoH JSON answer, or null.
  static String? parseJsonAnswer(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final Object? answers = decoded['Answer'];
      if (answers is! List) return null;
      for (final Object? a in answers) {
        if (a is! Map) continue;
        final Object? data = a['data'];
        if (data is! String) continue;
        for (final String part in data.split(RegExp(r'\s+'))) {
          if (part.startsWith('ech=')) {
            final String v = part.substring(4).trim();
            if (v.isNotEmpty) return v;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
