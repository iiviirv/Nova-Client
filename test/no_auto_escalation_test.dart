import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_env.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Tester, 2026-10-10, after a week on both Iranian firewalls: "every problem
/// that appeared at the start was caused by HTTP/2 fragment turning itself on.
/// It must never be turned on automatically." Fragmentation no longer gets
/// through any ISP he could find, so each automatic switch could only spend
/// time arriving at the same answer, and the ones that persisted left settings
/// on a profile that the user never chose.
void main() {
  group('nothing turns fragmentation on by itself', () {
    test('a MASQUE search that finds nothing does not retry with fragment',
        () async {
      final List<AetherOptions> seen = <AetherOptions>[];
      final AetherAdaptiveSearch search = AetherAdaptiveSearch(
        createSearch: () => _Recording(seen),
        fallbackAfter: const Duration(milliseconds: 50),
      );
      await search.run(const AetherOptions(), (_) {});
      expect(seen.length, 1,
          reason: 'one search. The second phase used to start after ninety '
              'seconds and scan again with a split ClientHello');
      expect(seen.single.fragment, isFalse);
    });

    test('a search left alone for a long time still does not', () async {
      final List<AetherOptions> seen = <AetherOptions>[];
      final AetherAdaptiveSearch search = AetherAdaptiveSearch(
        createSearch: () => _Recording(seen, delay: const Duration(seconds: 1)),
        fallbackAfter: const Duration(milliseconds: 20),
      );
      await search.run(const AetherOptions(), (_) {});
      expect(seen.every((AetherOptions o) => !o.fragment), isTrue);
      expect(seen.length, 1,
          reason: 'the timer used to fire mid-search and cancel a scan that '
              'was still making progress');
    });

    test('WireGuard still never fragments, which was always true', () async {
      final List<AetherOptions> seen = <AetherOptions>[];
      await AetherAdaptiveSearch(createSearch: () => _Recording(seen))
          .run(const AetherOptions(mode: AetherMode.wg, fragment: true), (_) {});
      expect(seen.single.fragment, isFalse);
    });
  });

  group('nothing turns a name bypass on by itself', () {
    test('the ladder function is gone from both controllers', () {
      for (final String path in <String>[
        'lib/src/core/proxy/singbox_proxy_controller.dart',
        'lib/src/core/proxy/desktop_proxy_controller.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src, isNot(contains('notice.value = ProxyNotice.sniBypassOn')),
            reason: '$path still switches the SNI bypass on by itself, which '
                'writes a setting the user never chose into their profile');
      }
    });

    test('a profile is never handed back with hardenTls or echSni turned on',
        () {
      // nextBypassStep is what the escalation used to consult. It still
      // describes the manual ladder, so it keeps working; what matters is
      // that nothing calls it to change a profile on the user's behalf.
      final ProxyProfile p = ProxyProfile(
          id: 'x', name: 'x', kind: ProxyKind.subscription, uri: 'https://e/s');
      expect(nextBypassStep(p)?.echSni, isTrue,
          reason: 'the rule itself is unchanged and still available by hand');
      final String src =
          File('lib/src/core/proxy/singbox_proxy_controller.dart')
              .readAsStringSync();
      expect(src, contains('Future<bool> _escalateToBypass'),
          reason: 'kept as a function so the call sites still read sensibly');
      expect(src, contains('async =>\n      false'),
          reason: 'and it answers "there is nothing automatic left to try"');
    });
  });

  test('the core asks for its ECH key the way that answers', () {
    // Corrected twice by the same tester: plain DNS to 1.1.1.1 answers on
    // these networks, the DoH endpoint does not.
    expect(AetherEnv.kEchDns, 'udp://1.1.1.1');
  });
}

/// Records what it was asked to search for and never finds anything.
class _Recording implements AetherGatewaySearch {
  _Recording(this.seen, {this.delay = Duration.zero});
  final List<AetherOptions> seen;
  final Duration delay;
  @override
  bool get available => true;
  @override
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async =>
      false;
  @override
  Future<AetherFindResult> run(
      AetherOptions options, ValueChanged<AetherSearchProgress> onProgress,
      {List<String> excludedFirst = const <String>[]}) async {
    seen.add(options);
    onProgress(
        const AetherSearchProgress(attempt: 1, verifying: false, ruledOut: 0));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return const AetherFindResult(
        endpoint: null, attempts: 1, rejected: <String>[], error: 'none');
  }
}
