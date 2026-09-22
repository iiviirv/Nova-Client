import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

class Search implements AetherGatewaySearch {
  final result = Completer<AetherFindResult>();
  final started = Completer<void>();
  List<String> excluded = [];
  AetherOptions? options;
  ValueChanged<AetherSearchProgress>? progress;
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
    this.options = options;
    excluded = excludedFirst;
    progress = onProgress;
    started.complete();
    return result.future;
  }
}

class Proxy extends ProxyController {
  Proxy(Search search) : super(gatewaySearchFactory: () => search);
  @override
  ProxyProfile? activeProfile;
  @override
  ProxyConnectionState state = ProxyConnectionState.connected;
  @override
  TrafficStats get traffic => TrafficStats.zero;
  @override
  String? get lastError => null;
  final events = <String>[];
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
    state = ProxyConnectionState.connected;
  }
}

void main() {
  final original = ProxyProfile(
      id: 'mine',
      name: 'My Aether',
      kind: ProxyKind.aether,
      uri: const AetherConfig(
              options: AetherOptions(peer: '[2606:4700:100::1]:443'))
          .toLink());
  const found = AetherFindResult(
      endpoint: '[2606:4700:100::2]:443',
      attempts: 2,
      rejected: [],
      options: AetherOptions(transport: AetherTransport.h2, fragment: true));

  test(
      'replacement stops VPN, reports progress, excludes old gateway and saves working transport',
      () async {
    final search = Search();
    final proxy = Proxy(search)..selectProfile(original);
    ProxyProfile? saved;
    proxy.persistProfile = (p) async {
      saved = p;
      proxy.events.add('save');
    };
    final replacing = proxy.replaceAetherGateway(original);
    await search.started.future;
    expect(proxy.events, ['stop']);
    expect(proxy.gatewaySearch.value?.replacing, isTrue);
    expect(search.excluded, ['[2606:4700:100::1]:443']);
    expect(search.options?.peer, isNull);
    search.progress!(const AetherSearchProgress(
        attempt: 2, verifying: true, ruledOut: 1, usingFallback: true));
    expect(proxy.gatewaySearch.value?.progress.verifying, isTrue);
    expect(proxy.gatewaySearch.value?.progress.usingFallback, isTrue);
    search.result.complete(found);
    expect(await replacing, isTrue);
    final config = AetherConfig.parse(saved!.uri)!;
    expect(config.gateway, '[2606:4700:100::2]:443');
    expect(config.options.transport, AetherTransport.h2);
    expect(config.options.fragment, isTrue);
    expect(proxy.events, ['stop', 'save', 'connect']);
    expect(proxy.gatewaySearch.value, isNull);
    proxy.dispose();
  });

  test('cancel discards late replacement and never reconnects', () async {
    final search = Search();
    final proxy = Proxy(search)..selectProfile(original);
    final replacing = proxy.replaceAetherGateway(original);
    await search.started.future;
    await proxy.toggle();
    search.progress!(
        const AetherSearchProgress(attempt: 9, verifying: true, ruledOut: 1));
    search.result.complete(found);
    expect(await replacing, isFalse);
    expect(proxy.gatewaySearch.value, isNull);
    expect(proxy.gatewaySearchCancelled, isTrue);
    expect(proxy.activeProfile, same(original));
    expect(proxy.events, ['stop', 'stop']);
    proxy.dispose();
  });
}
