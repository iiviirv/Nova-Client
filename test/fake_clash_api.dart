import 'dart:convert';
import 'dart:io';

/// A stand-in for the measuring core's Clash API, so the measuring path can be
/// driven end to end in tests without a real sing-box.
///
/// It answers `/version` and `/proxies/{tag}/delay`, records every delay call it
/// received, and lets a test script per-tag behaviour: a fixed latency, a
/// different latency on the second (warm) call, or no answer at all.
class FakeClashApi {
  FakeClashApi._(this._server);

  final HttpServer _server;
  int get port => _server.port;
  Uri get uri => Uri.parse('http://127.0.0.1:$port/');

  /// tag -> the latency each successive call answers with. A null entry is
  /// "this call fails" (503, like a node that did not respond). A tag missing
  /// from the map never answers.
  final Map<String, List<int?>> answers = <String, List<int?>>{};

  /// Every `(tag, url, timeoutMs)` the runner asked for, in order.
  final List<({String tag, String url, String timeout})> calls =
      <({String tag, String url, String timeout})>[];

  final Map<String, int> _seen = <String, int>{};

  static Future<FakeClashApi> start() async {
    final HttpServer s =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final FakeClashApi api = FakeClashApi._(s);
    s.listen(api._handle);
    return api;
  }

  Future<void> _handle(HttpRequest req) async {
    final List<String> parts = req.uri.pathSegments;
    if (parts.length == 1 && parts.first == 'version') {
      req.response
        ..statusCode = 200
        ..write('{"meta":true,"version":"fake"}');
      await req.response.close();
      return;
    }
    if (parts.length == 3 && parts[0] == 'proxies' && parts[2] == 'delay') {
      final String tag = parts[1];
      calls.add((
        tag: tag,
        url: req.uri.queryParameters['url'] ?? '',
        timeout: req.uri.queryParameters['timeout'] ?? '',
      ));
      final List<int?>? script = answers[tag];
      final int n = _seen.update(tag, (int v) => v + 1, ifAbsent: () => 1) - 1;
      final int? delay = script == null
          ? null
          : script[n < script.length ? n : script.length - 1];
      if (delay == null) {
        req.response
          ..statusCode = 503
          ..write('{"message":"An error occurred in the delay test"}');
      } else {
        req.response
          ..statusCode = 200
          ..write(jsonEncode(<String, int>{'delay': delay}));
      }
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
