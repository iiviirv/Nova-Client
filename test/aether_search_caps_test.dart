import 'dart:async';

import 'package:fake_async/fake_async.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Field report, build 168: a WireGuard search on Wi-Fi ran for three and a
/// half minutes and the tester stopped it by hand. Only MASQUE was capped,
/// because only MASQUE had somewhere to fall back to, so every other protocol
/// ran until the core gave up on its own.
///
/// Same report: WireGuard and Gool must never try fragmentation. It is a
/// MASQUE remedy. Some Iranian networks block fragmented hellos outright and
/// others pass only those, so applying it where it was never needed turns a
/// working protocol into a failing one.
class _Search implements AetherGatewaySearch {
  _Search(this.result);
  final Completer<AetherFindResult> result;
  AetherOptions? sawOptions;
  ValueChanged<AetherSearchProgress>? progress;
  @override
  bool cancelled = false;
  @override
  bool get available => true;
  @override
  void cancel() {
    cancelled = true;
    if (!result.isCompleted) {
      result.complete(const AetherFindResult(
          endpoint: null, attempts: 1, rejected: <String>[], error: 'cancelled'));
    }
  }

  @override
  Future<bool> verifyAddress(AetherOptions o, String e) async => false;
  @override
  Future<AetherFindResult> run(
      AetherOptions options, ValueChanged<AetherSearchProgress> onProgress,
      {List<String> excludedFirst = const <String>[]}) {
    sawOptions = options;
    progress = onProgress;
    return result.future;
  }
}

void main() {
  test('a scan that has started is given up on, not left running', () {
    fakeAsync((FakeAsync async) {
      final _Search first = _Search(Completer<AetherFindResult>());
      final search = AetherAdaptiveSearch(
          createSearch: () => first,
          fallbackAfter: const Duration(seconds: 90));
      search.run(const AetherOptions(mode: AetherMode.wg), (_) {});
      // Scanning has begun: the search reports its first attempt.
      first.progress!(const AetherSearchProgress(
          attempt: 1, verifying: false, ruledOut: 0));
      async.elapse(const Duration(seconds: 89));
      expect(first.cancelled, isFalse, reason: 'still within the budget');
      async.elapse(const Duration(seconds: 2));
      expect(first.cancelled, isTrue,
          reason: 'before this a WireGuard scan ran until the core gave up, '
              'which a tester measured at three and a half minutes');
    });
  });

  test('registration is not cancelled by the scan cap', () {
    fakeAsync((FakeAsync async) {
      final _Search first = _Search(Completer<AetherFindResult>());
      AetherAdaptiveSearch(
              createSearch: () => first,
              fallbackAfter: const Duration(seconds: 90))
          .run(const AetherOptions(mode: AetherMode.wg), (_) {});
      // No progress yet: the core is still registering, which on a blocking
      // network means minutes of camouflaged routes.
      async.elapse(const Duration(minutes: 2));
      expect(first.cancelled, isFalse,
          reason: 'the cap used to start here and cancelled the one step that '
              'could have succeeded, reporting "cancelled" about a phase the '
              'user had never been shown');
    });
  });

  test('WireGuard never searches with fragmentation, even if asked', () {
    final _Search first = _Search(Completer<AetherFindResult>());
    AetherAdaptiveSearch(createSearch: () => first).run(
        const AetherOptions(mode: AetherMode.wg, fragment: true), (_) {});
    expect(first.sawOptions!.fragment, isFalse,
        reason: 'fragmentation is a MASQUE remedy; on networks that block '
            'fragmented hellos it turns a working protocol into a broken one');
  });

  test('Gool never searches with fragmentation either', () {
    final _Search first = _Search(Completer<AetherFindResult>());
    AetherAdaptiveSearch(createSearch: () => first).run(
        const AetherOptions(mode: AetherMode.gool, fragment: true), (_) {});
    expect(first.sawOptions!.fragment, isFalse);
  });

  test('MASQUE keeps the fragmentation it was given, since it is the remedy',
      () {
    final _Search first = _Search(Completer<AetherFindResult>());
    AetherAdaptiveSearch(createSearch: () => first).run(
        const AetherOptions(mode: AetherMode.masque, fragment: true), (_) {});
    expect(first.sawOptions!.fragment, isTrue);
  });
}
