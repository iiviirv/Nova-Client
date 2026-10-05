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

  /// DoH, in whichever dialect the endpoint speaks.
  ///
  /// There are two, and which one a provider offers is not something the URL
  /// tells you. Cloudflare and Google answer a JSON query; Quad9 and OpenDNS
  /// answer only RFC 8484 wire format, and measured against them the JSON
  /// request simply fails. Since the point of having several resolvers is that
  /// a blocking network may leave only one of them reachable, a provider that
  /// is reachable and merely speaks the other dialect is not one to waste.
  static Future<String?> _overDoh(
      String domain, String url, Duration timeout) async {
    return await _dohJson(domain, url, timeout) ??
        await _dohWire(domain, url, timeout);
  }

  static Future<String?> _dohJson(
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
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// RFC 8484: the query as base64url in `?dns=`, the answer in wire format,
  /// which is the same bytes [parseWireAnswer] already reads off a socket.
  static Future<String?> _dohWire(
      String domain, String url, Duration timeout) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final String q = base64Url
          .encode(buildQuery(domain, id: 0))
          .replaceAll('=', ''); // unpadded, as the RFC requires
      final Uri u = Uri.parse(url)
          .replace(queryParameters: <String, String>{'dns': q});
      final HttpClientRequest req = await client.getUrl(u);
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
      final HttpClientResponse res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;
      final List<int> body =
          await res.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b));
      return parseWireAnswer(Uint8List.fromList(body),
          expectId: 0, expectName: domain);
    } catch (_) {
      return null;
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
      final int id = Random().nextInt(0x10000);
      final Uint8List query = buildQuery(domain, id: id);
      sock.send(query, addrs.first, port);
      final Completer<Uint8List?> done = Completer<Uint8List?>();
      // Only an answer from the server we asked, to the question we asked,
      // carrying the id we chose. None of that was checked, and the answer
      // becomes the ECH key: whoever supplies it holds the private half, so
      // they can decrypt the inner ClientHello and read the real server name.
      // That is the one thing ECH exists to stop, and ECH also turns off
      // fragmentation, so a forged key left the name MORE exposed than ECH off.
      //
      // Measured before the fix with a local server replying id=0xBEEF, zero
      // questions and a record for another name entirely: accepted. On-path is
      // not even needed, since without the id check only the source port has
      // to be guessed.
      final StreamSubscription<RawSocketEvent> sub =
          sock.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = sock.receive();
        if (d == null || done.isCompleted) return;
        if (d.address != addrs.first || d.port != port) return;
        final Uint8List bytes = Uint8List.fromList(d.data);
        // Keep listening after a datagram that does not answer the question.
        // Completing on it would let one forgery deny the real answer that is
        // still in flight.
        if (!_answersQuery(bytes, id, domain)) return;
        done.complete(bytes);
      });
      try {
        final Uint8List? reply =
            await done.future.timeout(timeout, onTimeout: () => null);
        return reply == null
            ? null
            : parseWireAnswer(reply, expectId: id, expectName: domain);
      } finally {
        await sub.cancel();
      }
    } finally {
      sock.close();
    }
  }

  /// Whether [msg] is a reply to our query: our id, and the one question we
  /// asked echoed back. Cheap enough to run on every datagram that arrives.
  static bool _answersQuery(Uint8List msg, int id, String domain) {
    if (msg.length < 12) return false;
    if (((msg[0] << 8) | msg[1]) != id) return false;
    if (((msg[4] << 8) | msg[5]) != 1) return false;
    final (String qname, int _) = _nameAt(msg, 12);
    return _sameName(qname, domain);
  }

  static Future<String?> _overTcp(
      String domain, String hostPort, Duration timeout) async {
    final (String host, int port) = _hostPort(hostPort, 53);
    final Socket sock =
        await Socket.connect(host, port, timeout: timeout);
    try {
      final int id = Random().nextInt(0x10000);
      final Uint8List q = buildQuery(domain, id: id);
      // DNS over TCP prefixes the message with its length.
      sock.add(<int>[(q.length >> 8) & 0xFF, q.length & 0xFF, ...q]);
      await sock.flush();
      final List<int> buf = <int>[];
      await for (final List<int> chunk in sock.timeout(timeout)) {
        buf.addAll(chunk);
        if (buf.length >= 2) {
          final int want = (buf[0] << 8) | buf[1];
          if (buf.length >= 2 + want) {
            return parseWireAnswer(Uint8List.fromList(buf.sublist(2, 2 + want)),
                expectId: id, expectName: domain);
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
  ///
  /// Pass [expectId] and [expectName] wherever the answer came off a socket
  /// rather than out of an authenticated response body. Without them this
  /// reads whatever arrived, and what it reads becomes the ECH key.
  static String? parseWireAnswer(Uint8List msg,
      {int? expectId, String? expectName}) {
    try {
      if (msg.length < 12) return null;
      if (expectId != null && ((msg[0] << 8) | msg[1]) != expectId) return null;
      final int qd = (msg[4] << 8) | msg[5];
      final int an = (msg[6] << 8) | msg[7];
      if (an == 0) return null;
      // A reply to one question echoes exactly that one question. Anything
      // else is not answering what was asked.
      if (expectName != null && qd != 1) return null;
      int i = 12;
      for (int q = 0; q < qd; q++) {
        if (q == 0 && expectName != null) {
          final (String qname, int _) = _nameAt(msg, i);
          if (!_sameName(qname, expectName)) return null;
        }
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

  /// Strips a matched pair of surrounding quotes, and nothing else.
  static String _unquote(String v) {
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  /// Past a name, following a compression pointer if there is one.
  /// The name at [i] as dotted text, and the offset just past it on the wire.
  ///
  /// Compression pointers are followed, so a question echoed by reference
  /// still reads. The second value is the on-wire end, which for a pointer is
  /// two bytes on from where it started, not the end of what it pointed at.
  static (String name, int next) _nameAt(Uint8List msg, int i) {
    final List<String> labels = <String>[];
    int at = i;
    int? next;
    // Bounded: a malformed message must not spin here, and 64 hops is far
    // more than any real name needs.
    for (int hops = 0; hops < 64; hops++) {
      if (at < 0 || at >= msg.length) break;
      final int n = msg[at];
      if (n == 0) {
        next ??= at + 1;
        break;
      }
      if ((n & 0xC0) == 0xC0) {
        if (at + 1 >= msg.length) break;
        next ??= at + 2;
        at = ((n & 0x3F) << 8) | msg[at + 1];
        continue;
      }
      if (at + 1 + n > msg.length) break;
      labels.add(
          String.fromCharCodes(msg.sublist(at + 1, at + 1 + n)));
      at += 1 + n;
    }
    return (labels.join('.'), next ?? at);
  }

  /// DNS names compare without case and without a trailing root dot.
  static bool _sameName(String a, String b) {
    String trim(String s) {
      String t = s.trim().toLowerCase();
      while (t.endsWith('.')) {
        t = t.substring(0, t.length - 1);
      }
      return t;
    }

    final String x = trim(a);
    return x.isNotEmpty && x == trim(b);
  }

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
            // Some providers quote the value inside the record text and some
            // do not. Measured: NextDNS and doh.sb return ech="AEX..." while
            // Cloudflare and Google return it bare. A key carrying a stray
            // quote is not a key; it is refused exactly like a stale one, and
            // silently, which is the failure this whole area keeps producing.
            final String v = _unquote(part.substring(4).trim());
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
