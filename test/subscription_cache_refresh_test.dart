import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// The bug this guards: the automatic refresh was a no-op for anyone who left
/// Nova running.
///
/// Resolved nodes are cached for the life of the process, keyed by the
/// subscription URL, so the free list's staleness timer would fire, ask for the
/// list again, and be handed back the same servers it had cached hours earlier.
/// Only a cold start or the manual refresh button ever went to the network. The
/// free list is rebuilt upstream every hour and loses roughly 40% of its
/// servers in four, so those users held a mostly-dead list indefinitely.
///
/// The fix is per-profile, and that part matters as much: the global clear
/// would have made one list going stale cost every other list its resolved
/// nodes, which is the cost this cache exists to avoid.
void main() {
  const String freeUrl = 'https://raw.example/sub.txt';
  const String mineUrl = 'https://panel.example/sub?key=abc';

  ProxyProfile sub(String id, String url) => ProxyProfile(
        id: id,
        name: id,
        kind: ProxyKind.subscription,
        uri: '',
        subscriptionUrl: url,
      );

  ProxyNode node(String tag) => ProxyNode(
        protocol: NodeProtocol.vless,
        server: '172.67.70.1',
        port: 2053,
        uuid: '11111111-1111-4111-8111-111111111111',
        tag: tag,
      );

  setUp(() {
    clearSubscriptionCache();
    debugSeedSubscriptionCache(freeUrl, <ProxyNode>[node('free')]);
    debugSeedSubscriptionCache(mineUrl, <ProxyNode>[node('mine')]);
  });

  tearDown(clearSubscriptionCache);

  test('a stale list forgets its own cached nodes, so the refresh refetches',
      () {
    forgetProfileNodes(sub('nova-free', freeUrl));
    expect(debugSubscriptionCacheKeys(), isNot(contains(freeUrl)));
  });

  test('and leaves every other profile alone', () {
    forgetProfileNodes(sub('nova-free', freeUrl));
    expect(debugSubscriptionCacheKeys(), contains(mineUrl),
        reason: 'one list going stale must not re-fetch all the others');
  });

  test('the manual refresh still drops everything', () {
    clearSubscriptionCache();
    expect(debugSubscriptionCacheKeys(), isEmpty);
  });

  test('forgetting a profile that was never cached is not an error', () {
    forgetProfileNodes(sub('x', 'https://never.example/sub'));
    expect(debugSubscriptionCacheKeys(), hasLength(2));
  });

  test('a profile carrying its URL in uri rather than subscriptionUrl is found',
      () {
    forgetProfileNodes(ProxyProfile(
      id: 'nova-free',
      name: 'free',
      kind: ProxyKind.subscription,
      uri: freeUrl,
    ));
    expect(debugSubscriptionCacheKeys(), isNot(contains(freeUrl)),
        reason: 'either field may legitimately hold the URL');
  });
}
