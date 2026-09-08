import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// The free list is published at two addresses, and either can serve it.
///
/// The new one exists so the list can eventually be published with no addresses
/// in it, which older clients cannot read. Falling back is what makes that move
/// need no coordination: the new file can be created whenever it is ready, and
/// until then this client behaves exactly like the last one.
///
/// Without it, shipping a client that points at a file nobody has created yet
/// would 404 the free list for every user at once, which is precisely what the
/// migration in this release would have caused.
void main() {
  ProxyProfile freeAt(String url) => ProxyProfile(
        id: kFreeProfileId,
        name: 'Nova free servers',
        kind: ProxyKind.subscription,
        uri: url,
        subscriptionUrl: url,
      );

  const String oneNode =
      'vless://00000000-0000-0000-0000-000000000000@a.example.com:443'
      '?type=ws&security=tls&sni=a.example.com&path=%2Fws#A';

  test('the new URL falls back to the old one when it does not exist yet',
      () async {
    int v2Tries = 0;
    final List<ProxyNode> nodes = await resolveProfileNodes(
      freeAt(kFreeSubUrl),
      fetch: (Uri u) async {
        if (u.toString() == kFreeSubUrl) {
          v2Tries++;
          throw Exception('404 not found');
        }
        return oneNode;
      },
    );
    expect(v2Tries, 1, reason: 'the new address is tried first');
    expect(nodes, hasLength(1),
        reason: 'a file that does not exist yet must not empty the free list');
  });

  test('the old URL falls back to the new one', () async {
    final List<ProxyNode> nodes = await resolveProfileNodes(
      freeAt(kFreeSubUrlLegacy),
      fetch: (Uri u) async {
        if (u.toString() == kFreeSubUrlLegacy) throw Exception('blocked');
        return oneNode;
      },
    );
    expect(nodes, hasLength(1),
        reason: 'if one address is ever blocked the list keeps working');
  });

  test("a user's own subscription is NEVER fetched from somewhere else",
      () async {
    // The hazard: a fallback that applied to any URL would quietly serve one
    // person's list to another person's profile.
    const String mine = 'https://example.com/my-list.txt';
    final List<Uri> asked = <Uri>[];
    await expectLater(
      resolveProfileNodes(
        ProxyProfile(
          id: 'mine',
          name: 'Mine',
          kind: ProxyKind.subscription,
          uri: mine,
          subscriptionUrl: mine,
        ),
        fetch: (Uri u) async {
          asked.add(u);
          throw Exception('down');
        },
      ),
      throwsA(anything),
    );
    expect(asked.map((Uri u) => u.toString()), <String>[mine],
        reason: 'only Nova\'s own two published addresses map to each other');
  });

  test('a working URL is not second-guessed', () async {
    int calls = 0;
    final List<ProxyNode> nodes = await resolveProfileNodes(
      freeAt(kFreeSubUrl),
      fetch: (Uri u) async {
        calls++;
        return oneNode;
      },
    );
    expect(calls, 1, reason: 'no extra request when the first one worked');
    expect(nodes, hasLength(1));
  });
}
