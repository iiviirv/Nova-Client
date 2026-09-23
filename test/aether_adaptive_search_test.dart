import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_first_connection.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

const failed =
    AetherFindResult(endpoint: null, attempts: 1, rejected: ['1.2.3.4:443']);
const success =
    AetherFindResult(endpoint: '1.2.3.4:443', attempts: 1, rejected: []);

class Search implements AetherGatewaySearch {
  final done = Completer<AetherFindResult>();
  AetherOptions? options;
  List<String>? excluded;
  bool stopped = false;
  @override
  bool get available => true;
  @override
  bool get cancelled => stopped;
  @override
  void cancel() {
    stopped = true;
  }

  @override
  Future<bool> verifyAddress(AetherOptions o, String e) async => true;
  @override
  Future<AetherFindResult> run(
      AetherOptions o, ValueChanged<AetherSearchProgress> p,
      {List<String> excludedFirst = const []}) {
    options = o;
    excluded = excludedFirst;
    return done.future;
  }
}

void main() {
  _firstConnectionGetsTheFallback();

  testWidgets('90 seconds cancels and awaits old work before HTTP2 fallback',
      (tester) async {
    final first = Search(), second = Search();
    int calls = 0;
    final progress = <AetherSearchProgress>[];
    final search =
        AetherAdaptiveSearch(createSearch: () => calls++ == 0 ? first : second);
    final result = search.run(
        const AetherOptions(fragmentSize: '20-30', fragmentDelay: '4-8'),
        progress.add,
        excludedFirst: ['1.2.3.4:443']);
    await tester.pump(const Duration(seconds: 89));
    expect(first.stopped, isFalse);
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(first.stopped, isTrue);
    expect(calls, 1);
    first.done.complete(failed);
    await tester.pump();
    expect(calls, 2);
    expect(second.excluded, isEmpty);
    expect(second.options!.transport, AetherTransport.h2);
    expect(second.options!.fragment, isTrue);
    expect(second.options!.fragmentSize, '20-30');
    expect(second.options!.fragmentDelay, '4-8');
    expect(progress.last.usingFallback, isTrue);
    second.done.complete(success);
    final found = await result;
    expect(found.endpoint, '1.2.3.4:443');
    expect(found.options!.transport, AetherTransport.h2);
    expect(found.options!.fragment, isTrue);
  });
  testWidgets('explicit cancellation never starts fallback', (tester) async {
    final first = Search();
    int calls = 0;
    final search = AetherAdaptiveSearch(createSearch: () {
      calls++;
      return first;
    });
    final result = search.run(const AetherOptions(), (_) {});
    search.cancel();
    first.done.complete(failed);
    await result;
    await tester.pump(const Duration(seconds: 100));
    expect(calls, 1);
    expect(search.cancelled, isTrue);
  });
  testWidgets('success does not switch transport after the deadline',
      (tester) async {
    final first = Search();
    int calls = 0;
    final search = AetherAdaptiveSearch(createSearch: () {
      calls++;
      return first;
    });
    final result = search.run(const AetherOptions(), (_) {});
    first.done.complete(success);
    expect((await result).ok, isTrue);
    await tester.pump(const Duration(seconds: 100));
    expect(first.stopped, isFalse);
    expect(calls, 1);
  });
  testWidgets('WireGuard gool and already fragmented H2 do not fall back',
      (tester) async {
    for (final o in [
      const AetherOptions(mode: AetherMode.wg),
      const AetherOptions(mode: AetherMode.gool),
      const AetherOptions(transport: AetherTransport.h2, fragment: true)
    ]) {
      final first = Search();
      int calls = 0;
      final search = AetherAdaptiveSearch(createSearch: () {
        calls++;
        return first;
      });
      final result = search.run(o, (_) {});
      await tester.pump(const Duration(seconds: 100));
      expect(first.stopped, isFalse);
      first.done.complete(failed);
      await result;
      expect(calls, 1);
    }
  });
  testWidgets('an early failure starts fallback without wasting 90 seconds',
      (tester) async {
    final first = Search(), second = Search();
    int calls = 0;
    final search =
        AetherAdaptiveSearch(createSearch: () => calls++ == 0 ? first : second);
    final result = search.run(const AetherOptions(), (_) {});
    first.done.complete(failed);
    await tester.pump();
    expect(calls, 2);
    second.done.complete(success);
    expect((await result).ok, isTrue);
  });
}

/// Field log, 2026-09-23, iPhone: a free MASQUE profile scanned for 120 seconds
/// on h3 and never tried the HTTP/2 fallback.
///
///     12:46:53  aether search: start, mode=masque, transport=h3, fragment=false
///     12:48:54  scan 1 took 120034ms: done
///
/// One search, no fallback, despite the fallback being documented at 90s. The
/// cause was wiring, not logic: AetherAdaptiveSearch holds the fallback and was
/// only ever built by the Aether editor. Tapping Connect on a built-in profile
/// goes through AetherFirstConnection, which built a plain AetherCoreSearch. So
/// the automatic MASQUE HTTP/2 fallback shipped in 1.26.0 could not fire on the
/// path almost every user takes.
void _firstConnectionGetsTheFallback() {
  test('a first connection searches with the fallback, not a plain core search',
      () {
    expect(AetherFirstConnection().createSearchForTest(), isA<AetherAdaptiveSearch>(),
        reason: 'without this the 90s HTTP/2 fallback can never fire for a '
            'built-in MASQUE profile');
  });
}
