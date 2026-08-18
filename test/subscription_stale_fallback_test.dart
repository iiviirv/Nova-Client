import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// The bug this guards: on a network that blocks the panel's domain, opening the
/// server list (or connecting) triggers a refresh that fails, and the failure
/// used to WIPE the whole list, leaving the user with nothing to connect to and
/// a "could not load nodes" error. A failed refresh must instead fall back to
/// the last good body, keep the servers, and flag itself as stale.

/// A body with two real VLESS nodes, the shape a Nova panel hands out.
const String _savedBody =
    'vless://11111111-1111-4111-8111-111111111111@172.67.70.1:2053'
    '?encryption=none&security=tls&type=ws&sni=a.workers.dev'
    '&host=a.workers.dev&path=%2Fp#One\n'
    'vless://22222222-2222-4222-8222-222222222222@104.16.0.2:2053'
    '?encryption=none&security=tls&type=ws&sni=a.workers.dev'
    '&host=a.workers.dev&path=%2Fp#Two';

class _FakeStore implements SubscriptionBodyStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> load(String url) async => _data[url];

  @override
  Future<void> save(String url, String body) async => _data[url] = body;
}

ProxyProfile _sub(String url) => ProxyProfile(
      id: 's',
      name: 'Nova',
      kind: ProxyKind.subscription,
      uri: '',
      subscriptionUrl: url,
    );

void main() {
  const String url = 'https://blocked.example.workers.dev/sub?key=abc';

  setUp(() {
    clearSubscriptionCache();
    subscriptionBodyStore = _FakeStore();
    lastResolveWasStale = false;
  });

  tearDown(() => subscriptionBodyStore = null);

  test('a failed refresh with a saved body serves it and flags stale', () async {
    (subscriptionBodyStore as _FakeStore)._data[url] = _savedBody;

    final List<dynamic> nodes = await resolveProfileNodes(
      _sub(url),
      // The panel is unreachable: every fetch throws, exactly like a blocked SNI.
      fetch: (Uri _) async => throw const HttpException('blocked'),
    );

    expect(nodes.length, 2, reason: 'the saved servers must survive the failure');
    expect(lastResolveWasStale, isTrue);
  });

  test('a failed refresh with NO saved body still throws (genuine first run)',
      () async {
    expect(
      () => resolveProfileNodes(
        _sub(url),
        fetch: (Uri _) async => throw const HttpException('blocked'),
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('a successful refresh saves the body for next time', () async {
    final _FakeStore store = subscriptionBodyStore as _FakeStore;
    expect(store._data.containsKey(url), isFalse);

    final List<dynamic> nodes = await resolveProfileNodes(
      _sub(url),
      fetch: (Uri _) async => _savedBody,
    );

    expect(nodes.length, 2);
    expect(lastResolveWasStale, isFalse);
    expect(store._data[url], _savedBody,
        reason: 'a good body is persisted so a later block can fall back to it');
  });

  test('after a save, a later blocked refresh falls back to the saved body',
      () async {
    // First, a good refresh persists the body.
    await resolveProfileNodes(_sub(url), fetch: (Uri _) async => _savedBody);
    clearSubscriptionCache(); // force the next call to actually re-fetch

    // Now the network blocks the panel: the list must still come back.
    final List<dynamic> nodes = await resolveProfileNodes(
      _sub(url),
      fetch: (Uri _) async => throw const HttpException('blocked'),
    );
    expect(nodes.length, 2);
    expect(lastResolveWasStale, isTrue);
  });

  test('a base64-encoded saved body is decoded on fallback', () async {
    (subscriptionBodyStore as _FakeStore)._data[url] =
        base64.encode(utf8.encode(_savedBody));

    final List<dynamic> nodes = await resolveProfileNodes(
      _sub(url),
      fetch: (Uri _) async => throw const HttpException('blocked'),
    );
    expect(nodes.length, 2);
    expect(lastResolveWasStale, isTrue);
  });
}
