import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nova_client/src/features/cloudflare/doh_resolver.dart';

void main() {
  test('parses A records from a JSON DoH answer', () async {
    final DohResolver doh = DohResolver(
      client: MockClient((http.Request req) async {
        expect(req.url.host, 'cloudflare-dns.com');
        expect(req.url.queryParameters['name'], 'novaproxy.online');
        expect(req.url.queryParameters['type'], 'A');
        return http.Response(
          '{"Answer":[{"type":1,"data":"172.64.80.1"},'
          '{"type":1,"data":"104.18.0.1"}]}',
          200,
        );
      }),
    );
    expect(await doh.resolveA('novaproxy.online'),
        <String>['172.64.80.1', '104.18.0.1']);
  });

  test('ignores non-A answers (e.g. CNAME) and junk', () async {
    final DohResolver doh = DohResolver(
      client: MockClient((http.Request req) async => http.Response(
            '{"Answer":[{"type":5,"data":"foo.example"},'
            '{"type":1,"data":"not-an-ip"},'
            '{"type":1,"data":"203.0.113.7"}]}',
            200,
          )),
    );
    expect(await doh.resolveA('x.test'), <String>['203.0.113.7']);
  });

  test('falls through to the second endpoint when the first fails', () async {
    int calls = 0;
    final DohResolver doh = DohResolver(
      client: MockClient((http.Request req) async {
        calls++;
        if (req.url.host == 'cloudflare-dns.com') {
          throw Exception('blocked');
        }
        return http.Response('{"Answer":[{"type":1,"data":"198.51.100.9"}]}', 200);
      }),
    );
    expect(await doh.resolveA('x.test'), <String>['198.51.100.9']);
    expect(calls, 2); // tried cloudflare, then google
  });

  test('returns empty when nothing resolves, so caller uses system DNS', () async {
    final DohResolver doh = DohResolver(
      client: MockClient((http.Request req) async => http.Response('{}', 200)),
    );
    expect(await doh.resolveA('x.test'), isEmpty);
  });

  test('caches a successful answer (one network round, not two)', () async {
    int calls = 0;
    final DohResolver doh = DohResolver(
      client: MockClient((http.Request req) async {
        calls++;
        return http.Response('{"Answer":[{"type":1,"data":"192.0.2.5"}]}', 200);
      }),
    );
    await doh.resolveA('x.test');
    await doh.resolveA('x.test');
    expect(calls, 1);
  });
}
