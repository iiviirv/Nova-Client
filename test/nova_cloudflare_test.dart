import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_client/src/features/cloudflare/nova_cloudflare.dart';

class _MemStore implements CfStore {
  final Map<String, String> _m = {};
  @override
  String get(String k) => _m[k] ?? '';
  @override
  void set(String k, String v) => _m[k] = v;
}

void main() {
  test('PKCE authorize URL is well-formed', () {
    final cf = NovaCloudflare(_MemStore());
    const verifier = 'test-verifier-abc123';
    final a = cf.authorizeUrl(verifier);
    final expectedChallenge =
        base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    expect(a.url, contains('client_id=54d11594-84e4-41aa-b438-e81b8fa78ee7'));
    expect(a.url, contains('code_challenge_method=S256'));
    expect(a.url, contains('code_challenge=$expectedChallenge'));
    expect(a.url, contains('redirect_uri='));
    expect(a.state.isNotEmpty, isTrue);
  });

  test('worker source is fetchable (deploy step 1)', () async {
    final r = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/IRNova/Nova-Proxy/refs/heads/main/worker.js'));
    expect(r.statusCode, 200);
    expect(r.bodyBytes.length, greaterThan(1000));
  });

  test('falls back to the proxy when the direct call throws', () async {
    final hosts = <String>[];
    final client = MockClient((http.Request req) async {
      hosts.add(req.url.host);
      if (req.url.host == 'api.cloudflare.com') {
        throw const SocketException('Failed host lookup: api.cloudflare.com');
      }
      return http.Response('{}', 200); // proxy relay succeeds
    });
    final cf = NovaCloudflare(_MemStore(), client: client);
    final s = const CfSession(token: 't', accountId: 'a', accountName: 'n');
    // deleteWorker uses the _http path and only succeeds on a 2xx.
    await cf.deleteWorker(s, 'w1');
    expect(hosts, contains('api.cloudflare.com')); // direct tried first
    expect(hosts, contains('novaproxy.online')); // then the proxy
  });

  test('sticks to the proxy on the next call, skipping the dead direct path',
      () async {
    final hosts = <String>[];
    final client = MockClient((http.Request req) async {
      hosts.add(req.url.host);
      if (req.url.host == 'api.cloudflare.com') {
        throw const SocketException('blocked');
      }
      return http.Response('{}', 200);
    });
    final cf = NovaCloudflare(_MemStore(), client: client);
    final s = const CfSession(token: 't', accountId: 'a', accountName: 'n');
    await cf.deleteWorker(s, 'w1'); // learns the proxy works
    hosts.clear();
    await cf.deleteWorker(s, 'w2'); // should hit the proxy first now
    expect(hosts.first, 'novaproxy.online');
  });

  test('a non-2xx direct response is returned as-is, not re-routed to proxy',
      () async {
    final hosts = <String>[];
    final client = MockClient((http.Request req) async {
      hosts.add(req.url.host);
      return http.Response('{"error":"nope"}', 404);
    });
    final cf = NovaCloudflare(_MemStore(), client: client);
    final s = const CfSession(token: 't', accountId: 'a', accountName: 'n');
    // A reachable server that answers 404 must not trigger the proxy fallback.
    await expectLater(cf.deleteWorker(s, 'w1'), throwsA(isA<CloudflareException>()));
    expect(hosts, <String>['api.cloudflare.com']);
  });
}
