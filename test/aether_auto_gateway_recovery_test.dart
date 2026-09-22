import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/logging/nova_log.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Field report, build 162: a WireGuard profile built on Wi-Fi connected, and
/// the same profile on a mobile carrier sat in "checking" for 45 seconds and
/// then gave up, because the saved gateway is blocked on that carrier. The
/// remedy existed but was only reachable after a tunnel that came up went
/// quiet, never after one that failed to come up at all.

class Search implements AetherGatewaySearch {
  final result = Completer<AetherFindResult>();
  final started = Completer<void>();
  List<String> excluded = const <String>[];
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
      {List<String> excludedFirst = const []}) {
    excluded = excludedFirst;
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

class Proxy extends ProxyController {
  Proxy(AetherGatewaySearch Function() factory)
      : super(gatewaySearchFactory: factory);
  @override
  ProxyProfile? activeProfile;
  @override
  ProxyConnectionState state = ProxyConnectionState.connected;
  @override
  TrafficStats get traffic => TrafficStats.zero;
  @override
  String? get lastError => null;
  final events = <String>[];

  /// Lets a test make the reconnect fail the same way the first attempt did.
  Future<void> Function(Proxy self)? onConnect;

  @override
  void selectProfile(ProxyProfile? profile) => activeProfile = profile;

  @override
  Future<void> disconnect() async {
    cancelAetherSearch();
    events.add('stop');
    state = ProxyConnectionState.disconnected;
  }

  @override
  Future<void> connect() async {
    events.add('connect');
    if (onConnect != null) return onConnect!(this);
    state = ProxyConnectionState.connected;
  }
}

String _appLog() => NovaLog.instance
    .lines(NovaLogSource.app)
    .map((NovaLogEntry e) => e.message)
    .join('\n');

void main() {
  const String dead = '[2606:4700:100::1]:443';
  final ProxyProfile aether = ProxyProfile(
      id: 'mine',
      name: 'My Aether',
      kind: ProxyKind.aether,
      uri: const AetherConfig(options: AetherOptions(peer: dead)).toLink());
  const AetherFindResult found = AetherFindResult(
      endpoint: '[2606:4700:100::2]:443', attempts: 2, rejected: <String>[]);

  /// The search is created several async hops inside the call under test, so
  /// a test cannot read it off the list on the very next line.
  Future<Search> nthSearch(List<Search> searches, int n) async {
    for (int i = 0; i < 500 && searches.length <= n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(searches.length, greaterThan(n), reason: 'no search was started');
    return searches[n];
  }

  ({Proxy proxy, List<Search> searches}) build() {
    final List<Search> searches = <Search>[];
    final Proxy proxy = Proxy(() {
      final Search s = Search();
      searches.add(s);
      return s;
    });
    proxy.persistProfile = (ProxyProfile p) async => proxy.events.add('save');
    return (proxy: proxy, searches: searches);
  }

  test('a tunnel that never opened its port searches for another gateway',
      () async {
    final rig = build();
    rig.proxy.selectProfile(aether);
    final Future<bool> recovering =
        rig.proxy.autoReplaceStaleAetherGateway(AetherUnavailable(
            'the tunnel did not open its local proxy before the startup deadline'));
    final Search first = await nthSearch(rig.searches, 0);
    await first.started.future;
    // The gateway that just failed is tried last, not first.
    expect(first.excluded, <String>[dead]);
    first.result.complete(found);
    expect(await recovering, isTrue);
    expect(rig.proxy.events, <String>['stop', 'save', 'connect']);
  });

  test('a replacement that also fails does not start a second search',
      () async {
    final rig = build();
    rig.proxy.selectProfile(aether);
    bool? nested;
    rig.proxy.onConnect = (Proxy self) async {
      // The reconnect dies exactly as the first attempt did.
      nested = await self
          .autoReplaceStaleAetherGateway(AetherUnavailable('deadline again'));
      self.state = ProxyConnectionState.error;
    };
    final Future<bool> recovering = rig.proxy
        .autoReplaceStaleAetherGateway(AetherUnavailable('deadline'));
    final Search first = await nthSearch(rig.searches, 0);
    await first.started.future;
    first.result.complete(found);
    expect(await recovering, isFalse, reason: 'the reconnect errored');
    expect(nested, isFalse, reason: 'the nested call must be refused');
    expect(rig.searches, hasLength(1));
  });

  test('a search that found nothing reports failure without reconnecting',
      () async {
    final rig = build();
    rig.proxy.selectProfile(aether);
    final Future<bool> recovering = rig.proxy
        .autoReplaceStaleAetherGateway(AetherUnavailable('deadline'));
    final Search first = await nthSearch(rig.searches, 0);
    await first.started.future;
    first.result
        .complete(const AetherFindResult(
            endpoint: null,
            attempts: 9,
            rejected: <String>[],
            error: 'nothing answered'));
    expect(await recovering, isFalse);
    expect(rig.proxy.events, isNot(contains('connect')));
  });

  test('an error that is not an Aether startup failure searches for nothing',
      () async {
    final rig = build();
    rig.proxy.selectProfile(aether);
    NovaLog.instance.clear(NovaLogSource.app);
    expect(await rig.proxy.autoReplaceStaleAetherGateway(StateError('boom')),
        isFalse);
    expect(rig.searches, isEmpty);
    expect(_appLog(), isNot(contains('Looking for another one')));
  });

  // replaceAetherGateway refuses a non-Aether profile on its own, so the only
  // thing this guard still buys is not announcing a search that never happens.
  // The log is what a tester pastes into a report, so a promise it does not
  // keep is worse than no line at all.
  test('a non-Aether profile searches for nothing and says nothing', () async {
    final rig = build();
    rig.proxy.selectProfile(ProxyProfile(
        id: 'sub', name: 'Sub', kind: ProxyKind.subscription, uri: ''));
    NovaLog.instance.clear(NovaLogSource.app);
    expect(
        await rig.proxy.autoReplaceStaleAetherGateway(
            AetherUnavailable('deadline')),
        isFalse);
    expect(rig.searches, isEmpty);
    expect(_appLog(), isNot(contains('Looking for another one')));
  });

  test('a search the user cancelled is not restarted behind their back',
      () async {
    final rig = build();
    rig.proxy.selectProfile(aether);
    rig.proxy.gatewaySearchCancelled = true;
    expect(
        await rig.proxy.autoReplaceStaleAetherGateway(
            AetherUnavailable('deadline')),
        isFalse);
    expect(rig.searches, isEmpty);
  });
}
