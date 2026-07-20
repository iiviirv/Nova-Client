import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_client/src/features/relay/relay_client.dart';

void main() {
  test('RelayClient wraps a request into the MHR envelope and decodes the reply', () async {
    late Map<String, dynamic> sentEnvelope;
    late String sentTo;

    final MockClient inner = MockClient((http.Request req) async {
      sentTo = req.url.toString();
      sentEnvelope = jsonDecode(req.body) as Map<String, dynamic>;
      // Reply as the relay would: fetched a 200 with a body + a header.
      return http.Response(
        jsonEncode(<String, dynamic>{
          's': 200,
          'h': <String, String>{'content-type': 'text/plain', 'x-demo': 'ok'},
          'b': base64.encode(utf8.encode('hello via relay')),
        }),
        200,
      );
    });

    final RelayClient c = RelayClient(
      execUrl: 'https://script.google.com/macros/s/AKfyc/exec',
      authKey: 'secret-key',
      inner: inner,
    );

    final http.Response r = await c.get(
      Uri.parse('https://panel.example.com/sub?token=abc'),
      headers: <String, String>{'user-agent': 'Nova'},
    );

    // The client POSTed to the relay exec URL, not the target.
    expect(sentTo, 'https://script.google.com/macros/s/AKfyc/exec');
    expect(sentEnvelope['u'], 'https://panel.example.com/sub?token=abc');
    expect(sentEnvelope['m'], 'GET');
    expect(sentEnvelope['k'], 'secret-key');
    expect((sentEnvelope['h'] as Map)['user-agent'], 'Nova');

    // The decoded response is reconstructed faithfully.
    expect(r.statusCode, 200);
    expect(r.body, 'hello via relay');
    expect(r.headers['x-demo'], 'ok');
  });

  test('RelayClient surfaces a relay-level error as a RelayException', () async {
    final MockClient inner = MockClient((http.Request req) async {
      return http.Response(jsonEncode(<String, dynamic>{'e': 'target not allowed'}), 200);
    });
    final RelayClient c = RelayClient(execUrl: 'https://x/exec', inner: inner);
    expect(
      () => c.get(Uri.parse('https://blocked.example')),
      throwsA(isA<RelayException>()),
    );
  });
}
