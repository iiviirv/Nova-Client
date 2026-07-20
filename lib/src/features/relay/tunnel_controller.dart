import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'tunnel_client.dart';

/// Owns the "full tunnel through Google" data path: a local SOCKS5 proxy on this
/// device whose flows are carried, as tunnel ops, out through a node `/tunnel`
/// exit. Config is the exit URL + key + local port; the inner transport (fronted
/// / insecure / plain) is borrowed from the relay via [transport] so the tunnel
/// rides the same Google-fronted path. Persisted in the secure store.
class TunnelController extends ChangeNotifier {
  TunnelController(this.transport);

  /// Builds the inner http.Client for each tunnel op, given the exit URL, so the
  /// relay can decide fronted / insecure / plain by the endpoint (shared config).
  final http.Client? Function(String endpoint) transport;

  static const String _key = 'google_tunnel';
  static const int defaultPort = 1080;
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  bool _enabled = false;
  String _url = '';
  String _authKey = '';
  int _port = defaultPort;

  LocalSocks5? _socks;
  bool _running = false;

  bool get enabled => _enabled;
  String get url => _url;
  String get authKey => _authKey;
  int get port => _running ? _socks!.port : _port;
  bool get running => _running;

  /// Configured (has an exit URL) and switched on.
  bool get active => _enabled && _url.trim().isNotEmpty;

  Future<void> load() async {
    try {
      final String? raw = await _secure.read(key: _key);
      if (raw == null || raw.isEmpty) return;
      final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
      _enabled = j['enabled'] == true;
      _url = (j['url'] as String?) ?? '';
      _authKey = (j['authKey'] as String?) ?? '';
      _port = (j['port'] as int?) ?? defaultPort;
      notifyListeners();
    } catch (_) {/* ignore a corrupt blob */}
  }

  Future<void> save({bool? enabled, String? url, String? authKey, int? port}) async {
    if (enabled != null) _enabled = enabled;
    if (url != null) _url = url.trim();
    if (authKey != null) _authKey = authKey.trim();
    if (port != null) _port = port;
    await _secure.write(
      key: _key,
      value: jsonEncode(<String, dynamic>{
        'enabled': _enabled,
        'url': _url,
        'authKey': _authKey,
        'port': _port,
      }),
    );
    notifyListeners();
  }

  Future<void> clear() async {
    await stop();
    _enabled = false;
    _url = '';
    _authKey = '';
    _port = defaultPort;
    await _secure.delete(key: _key);
    notifyListeners();
  }

  RelayTunnel _mkTunnel() =>
      RelayTunnel(endpoint: _url, authKey: _authKey, inner: transport(_url));

  /// Start the local SOCKS5 listener. Returns the bound port. Idempotent.
  Future<int> start() async {
    if (_socks != null) return _socks!.port;
    final LocalSocks5 s = LocalSocks5(tunnelFactory: _mkTunnel);
    final int p = await s.start(_port);
    _socks = s;
    _running = true;
    notifyListeners();
    return p;
  }

  Future<void> stop() async {
    final LocalSocks5? s = _socks;
    _socks = null;
    _running = false;
    await s?.stop();
    notifyListeners();
  }

  /// Prove the whole path works: start the SOCKS5 (if needed), then fetch a tiny
  /// Google probe THROUGH it, so a pass means SOCKS5 -> tunnel op -> node exit ->
  /// internet all work. Throws [TunnelException] on any failure.
  Future<void> selfTest() async {
    if (_url.trim().isEmpty) throw TunnelException('set the tunnel exit URL first');
    final bool startedHere = _socks == null;
    final int p = await start();
    try {
      final int code = await _socksGet(
        proxyPort: p,
        host: 'www.gstatic.com',
        port: 80,
        path: '/generate_204',
      );
      if (code >= 400) {
        throw TunnelException('the tunnel reached Google but got HTTP $code');
      }
    } finally {
      if (startedHere) await stop();
    }
  }

  /// Minimal SOCKS5 client: CONNECT to [host]:[port] via the local proxy, send a
  /// tiny HTTP/1.0 GET, and return the response status code. Used only by
  /// [selfTest]; dart:io's HttpClient can't speak SOCKS5, so we drive it by hand.
  Future<int> _socksGet({
    required int proxyPort,
    required String host,
    required int port,
    required String path,
  }) async {
    final Socket sock = await Socket.connect('127.0.0.1', proxyPort,
        timeout: const Duration(seconds: 8));
    final _Reader r = _Reader(sock);
    try {
      // Greeting -> no-auth.
      sock.add(<int>[0x05, 0x01, 0x00]);
      final Uint8List greet = await r.take(2);
      if (greet[1] != 0x00) throw TunnelException('socks auth rejected');
      // CONNECT to host:port (domain atyp).
      final List<int> hb = utf8.encode(host);
      sock.add(<int>[
        0x05, 0x01, 0x00, 0x03, hb.length, ...hb, (port >> 8) & 0xff, port & 0xff,
      ]);
      final Uint8List rep = await r.take(4);
      if (rep[1] != 0x00) throw TunnelException('socks connect failed (${rep[1]})');
      // Consume the bound address per atyp.
      final int atyp = rep[3];
      if (atyp == 0x01) {
        await r.take(6);
      } else if (atyp == 0x03) {
        final int len = (await r.take(1))[0];
        await r.take(len + 2);
      } else if (atyp == 0x04) {
        await r.take(18);
      }
      // Send the request and read the status line.
      sock.add(utf8.encode('GET $path HTTP/1.0\r\nHost: $host\r\n\r\n'));
      final String line = await r.line().timeout(const Duration(seconds: 20));
      final Match? m = RegExp(r'HTTP/\d\.\d\s+(\d{3})').firstMatch(line);
      if (m == null) throw TunnelException('no HTTP status from tunnel');
      return int.parse(m.group(1)!);
    } finally {
      sock.destroy();
    }
  }
}

/// Tiny buffered reader for the self-test SOCKS5 client.
class _Reader {
  _Reader(Socket socket) {
    _sub = socket.listen((Uint8List c) {
      _buf.addAll(c);
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    }, onError: (_) {
      _done = true;
      _wake();
    }, cancelOnError: false);
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buf = <int>[];
  bool _done = false;
  Completer<void>? _w;

  void _wake() {
    final Completer<void>? w = _w;
    if (w != null && !w.isCompleted) {
      _w = null;
      w.complete();
    }
  }

  Future<Uint8List> take(int n) async {
    while (_buf.length < n) {
      if (_done) throw TunnelException('tunnel closed early');
      _w ??= Completer<void>();
      await _w!.future;
    }
    final Uint8List out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<String> line() async {
    while (true) {
      final int i = _buf.indexOf(0x0a);
      if (i >= 0) {
        final String s = utf8.decode(_buf.sublist(0, i));
        _buf.removeRange(0, i + 1);
        return s.trimRight();
      }
      if (_done) return utf8.decode(_buf);
      _w ??= Completer<void>();
      await _w!.future;
    }
  }

  Future<void> dispose() => _sub.cancel();
}
