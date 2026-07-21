import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_client/src/features/relay/tunnel_client.dart';

/// A fake `/tunnel` exit backed by an in-memory echo "server": connect returns
/// an id, data echoes what you write, and close ends it. Lets us exercise the
/// SOCKS5 server + op pump without any real network.
class _FakeExit {
  final Map<String, List<int>> _pending = <String, List<int>>{};
  int _n = 0;

  http.Client client() => MockClient((http.Request req) async {
        final Map<String, dynamic> op =
            jsonDecode(req.body) as Map<String, dynamic>;
        switch (op['op']) {
          case 'connect':
            final String id = 'sess${_n++}';
            _pending[id] = <int>[];
            return http.Response(jsonEncode(<String, dynamic>{'id': id}), 200);
          case 'data':
            final String id = op['id'] as String;
            if (!_pending.containsKey(id)) {
              return http.Response(jsonEncode(<String, dynamic>{'e': 'no session'}), 200);
            }
            if (op['d'] != null) {
              // Echo: stage the written bytes to come back on this same reply.
              _pending[id]!.addAll(base64.decode(op['d'] as String));
            }
            final List<int> out = _pending[id]!;
            _pending[id] = <int>[];
            return http.Response(
                jsonEncode(<String, dynamic>{
                  'd': out.isEmpty ? '' : base64.encode(out),
                  'closed': false,
                }),
                200);
          case 'close':
            _pending.remove(op['id']);
            return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
          default:
            return http.Response(jsonEncode(<String, dynamic>{'e': 'unknown op'}), 200);
        }
      });
}

// A minimal SOCKS5 client: CONNECT to host:port through [proxyPort], write
// [payload], read back [payload.length] echoed bytes.
Future<Uint8List> _socksEcho(int proxyPort, String host, int port, List<int> payload) async {
  final Socket s = await Socket.connect('127.0.0.1', proxyPort);
  final List<int> buf = <int>[];
  final sub = s.listen(buf.addAll);
  Future<void> until(int n) async {
    while (buf.length < n) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  s.add(<int>[0x05, 0x01, 0x00]);
  await until(2);
  buf.removeRange(0, 2);

  final List<int> hb = utf8.encode(host);
  s.add(<int>[0x05, 0x01, 0x00, 0x03, hb.length, ...hb, (port >> 8) & 0xff, port & 0xff]);
  await until(10); // 4 header + 4 addr + 2 port for atyp=1 reply
  buf.removeRange(0, 10);

  s.add(payload);
  await until(payload.length);
  final Uint8List got = Uint8List.fromList(buf.sublist(0, payload.length));
  await sub.cancel();
  s.destroy();
  return got;
}

void main() {
  test('SOCKS5 CONNECT round-trips bytes through the tunnel op protocol', () async {
    final _FakeExit exit = _FakeExit();
    final LocalSocks5 socks = LocalSocks5(
      tunnelFactory: () => RelayTunnel(
        endpoint: 'https://fake/tunnel',
        authKey: 'k',
        inner: exit.client(),
      ),
    );
    final int port = await socks.start(0);
    try {
      final Uint8List echoed =
          await _socksEcho(port, 'example.com', 80, utf8.encode('ping-123'));
      expect(utf8.decode(echoed), 'ping-123');
    } finally {
      await socks.stop();
    }
  });

  test('RelayTunnel maps op errors to TunnelException', () async {
    final RelayTunnel t = RelayTunnel(
      endpoint: 'https://fake/tunnel',
      authKey: 'k',
      inner: MockClient((_) async =>
          http.Response(jsonEncode(<String, dynamic>{'e': 'unauthorized'}), 200)),
    );
    expect(() => t.connect('example.com', 80), throwsA(isA<TunnelException>()));
    t.close();
  });
}
