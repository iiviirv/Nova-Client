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
  ValueChanged<AetherSearchProgress>? report;
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
    report = p;
    excluded = excludedFirst;
    return done.future;
  }
}

void main() {
  _firstConnectionGetsTheFallback();

  testWidgets('the cap gives up on the scan and starts nothing else',
      (tester) async {
    // This used to assert the opposite: that the cap cancelled the scan and
    // then ran a second one with HTTP/2 and a split ClientHello. Removed in
    // 1.31.1 at a tester's request, after a week on both Iranian firewalls.
    // Fragmentation no longer gets through any ISP he could find, and the
    // clock was being reached from ordinary slowness, so the retry could only
    // replace a search that might still succeed with one that could not.
    //
    // The cap itself stays, as a limit rather than a trigger. Without it a
    // WireGuard scan runs until the core gives up, measured at three and a
    // half minutes.
    final first = Search(), second = Search();
    int calls = 0;
    final progress = <AetherSearchProgress>[];
    final search =
        AetherAdaptiveSearch(createSearch: () => calls++ == 0 ? first : second);
    final result = search.run(
        const AetherOptions(fragmentSize: '20-30', fragmentDelay: '4-8'),
        progress.add,
        excludedFirst: ['1.2.3.4:443']);
    // The cap is on the scan and starts when the scan reports its first
    // attempt, so registration can run past it on a network that blocks the
    // direct call.
    first.report!(const AetherSearchProgress(
        attempt: 1, verifying: false, ruledOut: 0));
    await tester.pump(const Duration(seconds: 89));
    expect(first.stopped, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(first.stopped, isTrue, reason: 'the scan is given up on');
    first.done.complete(failed);
    await tester.pump();
    expect(calls, 1, reason: 'and nothing else is started');
    final found = await result;
    expect(found.ok, isFalse);
    expect(found.error, contains('90 seconds'),
        reason: 'the user is told the scan was given up on, not left guessing');
    expect(progress.any((p) => p.usingFallback), isFalse);
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
      // Not cancelled here: the cap is on the scan and starts when the scan
      // reports its first attempt, which this stub never does. Registration
      // must be able to run past it, because on a blocking network the core
      // spends minutes on camouflaged routes and cancelling that removes the
      // only step that could have succeeded. What this test is about is that
      // no second search is started for these protocols.
      expect(first.stopped, isFalse);
      first.done.complete(failed);
      await result;
      expect(calls, 1,
          reason: 'these protocols have nowhere to fall back to, so there must '
              'be no second search');
    }
  });
  testWidgets('an early failure is simply reported, with no second attempt',
      (tester) async {
    final first = Search(), second = Search();
    int calls = 0;
    final search =
        AetherAdaptiveSearch(createSearch: () => calls++ == 0 ? first : second);
    final result = search.run(const AetherOptions(), (_) {});
    first.done.complete(failed);
    await tester.pump();
    expect(calls, 1,
        reason: 'a failed search used to immediately start a fragmenting one');
    expect((await result).ok, isFalse);
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
