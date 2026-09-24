import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_config.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_engine.dart';

/// A stand-in for the engine process, so these tests exercise the waiting and
/// the giving up without needing a real Psiphon or a real network.
class _FakeProcess implements Process {
  _FakeProcess();
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  void say(String line) => _out.add(utf8.encode('$line\n'));
  void die(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    die(-1);
    return true;
  }

  @override
  int get pid => 4242;
  @override
  IOSink get stdin => throw UnimplementedError();
}

void main() {
  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('psi-test-'));
  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

  PsiphonConfig cfg() => PsiphonConfig(
      socksPort: 1081, dataDir: work.path, mode: PsiphonMode.direct);

  Future<PsiphonEngine> run(_FakeProcess p,
          {Duration budget = const Duration(seconds: 30),
          void Function(String)? log}) =>
      PsiphonEngine.start(
        binary: '/nonexistent/psiphon',
        config: cfg(),
        workDir: work,
        budget: budget,
        spawn: (_, __) async => p,
        log: log,
      );

  test('waits for a tunnel, not for the local port to open', () async {
    final p = _FakeProcess();
    final Future<PsiphonEngine> starting = run(p);
    // The listener opens first. This must NOT be taken as ready: nothing can
    // reach the internet yet.
    p.say('{"noticeType":"ListeningSocksProxyPort","data":{"port":1081}}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var done = false;
    unawaited(starting.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse, reason: 'the port is open but no tunnel exists yet');

    p.say('{"noticeType":"Tunnels","data":{"count":1}}');
    final PsiphonEngine e = await starting;
    expect(e.running, isTrue);
    expect(e.socksPort, 1081);
  });

  test('an engine that dies fails at once rather than after the whole budget',
      () async {
    final p = _FakeProcess();
    final Stopwatch clock = Stopwatch()..start();
    final Future<PsiphonEngine> starting =
        run(p, budget: const Duration(seconds: 30));
    p.die(1);
    await expectLater(starting, throwsA(isA<PsiphonUnavailable>()));
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'waiting out the budget for a dead engine wastes minutes');
  });

  test('gives up when no tunnel arrives', () async {
    final p = _FakeProcess();
    await expectLater(run(p, budget: const Duration(milliseconds: 150)),
        throwsA(isA<PsiphonUnavailable>()));
    expect(p.killed, isTrue, reason: 'a timed-out engine must not be left running');
  });

  test('an impossible config never starts a process', () async {
    var spawned = false;
    await expectLater(
      PsiphonEngine.start(
        binary: '/nonexistent/psiphon',
        // Chained with no upstream port: would silently dial direct.
        config: PsiphonConfig(
            socksPort: 1081,
            dataDir: work.path,
            mode: PsiphonMode.throughAether),
        workDir: work,
        spawn: (_, __) async {
          spawned = true;
          return _FakeProcess();
        },
      ),
      throwsA(isA<PsiphonUnavailable>()),
    );
    expect(spawned, isFalse);
  });

  test('addresses from the engine never reach the log', () async {
    final p = _FakeProcess();
    final lines = <String>[];
    final Future<PsiphonEngine> starting = run(p, log: lines.add);
    p.say('{"noticeType":"Warning","data":{"message":"peer 203.0.113.9 gone"}}');
    p.say('{"noticeType":"Tunnels","data":{"count":1}}');
    await starting;
    expect(lines.join('\n'), isNot(contains('203.0.113.9')));
    expect(lines.join('\n'), contains('[address removed]'));
  });

  test('the config it writes is the config the engine is given', () async {
    final p = _FakeProcess();
    final Future<PsiphonEngine> starting = run(p);
    p.say('{"noticeType":"Tunnels","data":{"count":1}}');
    await starting;
    final File conf = File('${work.path}/nova-psiphon.json');
    expect(conf.existsSync(), isTrue);
    final Map<String, Object?> written =
        jsonDecode(conf.readAsStringSync()) as Map<String, Object?>;
    expect(written['LocalSocksProxyPort'], 1081);
    expect(written['PropagationChannelId'], isNotEmpty);
  });
}
