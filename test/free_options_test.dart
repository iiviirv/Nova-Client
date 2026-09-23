import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_first_connection.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

class Search implements AetherGatewaySearch {
  final result = Completer<AetherFindResult>();
  int calls = 0;

  /// Held so a test can push progress back the way a running search does.
  ValueChanged<AetherSearchProgress>? report;
  @override
  bool get available => true;
  @override
  bool cancelled = false;
  @override
  void cancel() { cancelled = true; }
  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async => false;
  @override
  Future<AetherFindResult> run(AetherOptions options,
      ValueChanged<AetherSearchProgress> onProgress,
      {List<String> excludedFirst = const []}) {
    calls++;
    report = onProgress;
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('four defaults survive reload and keep saved gateways and user profiles', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProfilesController(prefs: prefs);
    expect(c.profiles.where((p) => p.isFreeOption), hasLength(4));
    final defaults = c.profiles.where((p) => p.kind == ProxyKind.aether).toList();
    expect(defaults.map((p) => AetherConfig.parse(p.uri)!.options.mode),
      [AetherMode.wg, AetherMode.gool, AetherMode.masque]);
    expect(defaults.every((p) => AetherConfig.parse(p.uri)!.gateway == null), isTrue);
    final saved = defaults.first.copyWith(uri: const AetherConfig(
      options: AetherOptions(mode: AetherMode.wg, peer: '162.159.198.1:443')).toLink());
    c.update(saved);
    c.add(ProxyProfile(id: 'user-wireguard', name: 'WireGuard', kind: ProxyKind.aether, uri: saved.uri));
    c.setActive('user-wireguard');
    for (final p in defaults) { c.remove(p.id); }
    final again = ProfilesController(prefs: prefs);
    expect(again.profiles, hasLength(5));
    expect(again.profiles.firstWhere((p) => p.id == saved.id).uri, saved.uri);
    expect(again.activeId, 'user-wireguard');
    expect(again.active!.isFreeOption, isTrue);
    expect(again.active!.isBuiltInFreeOption, isFalse);
  });
  test('selected tab persists including a choice before preferences attach', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProfilesController()..selectTab(false)..attachPrefs(prefs);
    expect(c.freeTab, isFalse);
    expect(ProfilesController(prefs: prefs).freeTab, isFalse);
    c.selectTab(true);
    expect(ProfilesController(prefs: prefs).freeTab, isTrue);
  });
  test('first connect saves endpoint and fallback; next connect does not search', () async {
    final search = Search();
    final first = AetherFirstConnection(createSearch: () => search);
    final progress = <AetherSearchProgress>[];
    final pending = first.prepare(buildFreeAetherProfiles().last, onProgress: progress.add);
    expect(progress, hasLength(1));
    expect(progress.single.verifying, isFalse);
    search.result.complete(const AetherFindResult(endpoint: '162.159.198.2:443',
      attempts: 1, rejected: [], options: AetherOptions(transport: AetherTransport.h2, fragment: true)));
    final ready = (await pending)!;
    final options = AetherConfig.parse(ready.uri)!.options;
    expect(options.peer, '162.159.198.2:443');
    expect(options.transport, AetherTransport.h2);
    expect(options.fragment, isTrue);
    expect(await first.prepare(ready), same(ready));
    expect(search.calls, 1);
  });
  test('progress says which protocol the search is running on', () async {
    // The card names the protocol to explain the wait, and the search itself
    // never knows which one it is on: it takes options, not a protocol. So the
    // tag is added here, on every update, or the card has nothing to say about
    // why a MASQUE search runs so much longer than the other two.
    final search = Search();
    final first = AetherFirstConnection(createSearch: () => search);
    final progress = <AetherSearchProgress>[];
    final pending = first.prepare(buildFreeAetherProfiles().last,
        onProgress: progress.add);
    expect(progress.single.mode, AetherMode.masque,
        reason: 'the first line is drawn before the search has reported '
            'anything, and that is the line the long wait starts under');
    search.report!(const AetherSearchProgress(
        attempt: 2, verifying: true, ruledOut: 1));
    expect(progress.last.mode, AetherMode.masque,
        reason: 'every update is tagged on the way past, not just the first');
    expect(progress.last.attempt, 2,
        reason: 'tagging must not lose what the search actually said');

    // A quicker protocol must not be described as the slow one.
    final wgSearch = Search();
    final wgProgress = <AetherSearchProgress>[];
    final wgPending = AetherFirstConnection(createSearch: () => wgSearch)
        .prepare(buildFreeAetherProfiles().first, onProgress: wgProgress.add);
    expect(wgProgress.single.mode, AetherMode.wg);

    search.result.complete(const AetherFindResult(
        endpoint: '162.159.198.2:443', attempts: 1, rejected: []));
    wgSearch.result.complete(const AetherFindResult(
        endpoint: '162.159.198.2:443', attempts: 1, rejected: []));
    await pending;
    await wgPending;
  });
  test('cancel discards a late successful result', () async {
    final search = Search();
    final first = AetherFirstConnection(createSearch: () => search);
    final pending = first.prepare(buildFreeAetherProfiles().first);
    first.cancel();
    search.result.complete(const AetherFindResult(endpoint: '162.159.198.2:443', attempts: 1, rejected: []));
    expect(await pending, isNull);
    expect(search.cancelled, isTrue);
  });
  test('failed discovery leaves profile unchanged and allows retry', () async {
    final search = Search();
    final first = AetherFirstConnection(createSearch: () => search);
    final profile = buildFreeAetherProfiles().first;
    final pending = first.prepare(profile);
    search.result.complete(const AetherFindResult(endpoint: null, error: 'offline', attempts: 1, rejected: []));
    await expectLater(pending, throwsFormatException);
    expect(AetherConfig.parse(profile.uri)!.gateway, isNull);
  });
}
