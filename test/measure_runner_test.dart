import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/measure_runner.dart';

import 'fake_clash_api.dart';

/// The lightning test's engine: one node at a time over the measuring core's
/// Clash API, warmed before it is timed, with a per-node timeout.
void main() {
  late FakeClashApi api;

  setUp(() async => api = await FakeClashApi.start());
  tearDown(() async => api.close());

  group('the test URL on the wire', () {
    test('a plain-http URL keeps its scheme in capitals', () {
      // sing-box throws away a URL starting with the literal "http://" and
      // substitutes its own https one, which adds a TLS handshake to every
      // measurement and roughly doubled every number. The check is
      // case-sensitive; Uri.parse lowercases the scheme either way.
      expect(MeasureRunner.wireUrl('http://www.gstatic.com/generate_204'),
          'HTTP://www.gstatic.com/generate_204');
      expect(Uri.parse(MeasureRunner.wireUrl('http://x.test/204')).scheme,
          'http');
    });

    test('https is left alone and empty falls back to the default', () {
      expect(MeasureRunner.wireUrl('https://x.test/204'), 'https://x.test/204');
      expect(MeasureRunner.wireUrl('  '),
          'HTTP://www.gstatic.com/generate_204');
    });
  });

  test('a node is dialled twice and the warm figure is the one reported',
      () async {
    // The cold dial pays the protocol's setup (mieru's session, naive's
    // TLS+HTTP/2); that is not the latency the user has once connected.
    api.answers['node-0'] = <int?>[420, 110];
    final Map<String, int> out = await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'key-a'},
      url: 'http://x.test/204',
      timeoutSec: 5,
    );
    expect(out, <String, int>{'key-a': 110});
    expect(api.calls.map((c) => c.tag), <String>['node-0', 'node-0']);
  });

  test('a slower second dial does not make the node look worse', () async {
    api.answers['node-0'] = <int?>[100, 900];
    final Map<String, int> out = await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'key-a'},
      url: 'http://x.test/204',
      timeoutSec: 5,
    );
    expect(out, <String, int>{'key-a': 100});
  });

  test('a node that misses its first dial gets one more chance', () async {
    // Busy servers answer late. On Nova's own free list four of eighteen failed
    // the first dial and answered the second, so writing a server off on one
    // miss hides working servers from the people who have nothing else.
    api.answers['node-0'] = <int?>[null, 300, 120];
    final Map<String, int> out = await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'key-a'},
      url: 'http://x.test/204',
      timeoutSec: 5,
    );
    expect(out, <String, int>{'key-a': 120});
  });

  test('a node that misses twice is no response, and is not dialled again',
      () async {
    api.answers['node-0'] = <int?>[null];
    final Map<String, int> out = await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'key-a'},
      url: 'http://x.test/204',
      timeoutSec: 5,
    );
    expect(out, isEmpty, reason: 'no response, not a latency');
    expect(api.calls, hasLength(2),
        reason: 'a dead node costs two timeouts, never more');
  });

  test('the timeout is sent per node and clamped to what the API can parse',
      () async {
    // sing-box parses `timeout` as an int16, so 60_000 would come back 400 Bad
    // Request and every node would read "no response".
    api.answers['node-0'] = <int?>[100];
    await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'key-a'},
      url: 'http://x.test/204',
      timeoutSec: 60,
    );
    expect(int.parse(api.calls.first.timeout),
        lessThanOrEqualTo(MeasureRunner.kMaxTimeoutMs));
    expect(int.parse(api.calls.first.timeout), greaterThan(0));
  });

  test('every node gets a verdict, and results are published as they land',
      () async {
    api.answers['node-0'] = <int?>[200, 100];
    api.answers['node-2'] = <int?>[300, 250];
    // node-1 never answers.
    final List<int> progress = <int>[];
    final Map<String, int> out = await MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{
        'node-0': 'a',
        'node-1': 'b',
        'node-2': 'c',
      },
      url: 'http://x.test/204',
      timeoutSec: 5,
      onProgress: (Map<String, int> d, Set<String> tested) =>
          progress.add(tested.length),
    );
    expect(out, <String, int>{'a': 100, 'c': 250});
    expect(progress, <int>[1, 2, 3],
        reason: 'the list fills in row by row, not all at once at the end');
  });

  test('cancelling stops the run', () async {
    api.answers['node-0'] = <int?>[100];
    api.answers['node-1'] = <int?>[100];
    bool stop = false;
    final Future<Map<String, int>> run = MeasureRunner.run(
      api: api.uri,
      tagKeys: <String, String>{'node-0': 'a', 'node-1': 'b'},
      url: 'http://x.test/204',
      timeoutSec: 5,
      concurrency: 1,
      cancelled: () => stop,
      onProgress: (_, __) => stop = true,
    );
    expect(await run, hasLength(1));
  });

  test('waitForApi answers once the core is listening', () async {
    expect(await MeasureRunner.waitForApi(api.uri), isTrue);
    expect(
        await MeasureRunner.waitForApi(Uri.parse('http://127.0.0.1:1/'),
            timeout: const Duration(milliseconds: 400)),
        isFalse);
  });
}
