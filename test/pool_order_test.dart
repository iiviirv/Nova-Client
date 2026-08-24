import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/pool_order.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The free list is published in one order, every device sweeps it in that
/// order, and the sweep stops once it has enough working servers. So every
/// device kept the same servers, the ones at the top, and a few volunteer
/// servers carried everyone while the rest of the pool sat unused.
void main() {
  List<ProxyNode> pool(int n) => <ProxyNode>[
        for (int i = 0; i < n; i++)
          ProxyNode(
            protocol: NodeProtocol.vless,
            server: '10.0.0.$i',
            port: 443,
            uuid: '11111111-2222-3333-4444-555555555555',
          ),
      ];

  String order(List<ProxyNode> l) => l.map((ProxyNode n) => n.server).join(',');

  test('two installs sweep the pool in different orders', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 1});
    await PoolOrder.load();
    final String a = order(PoolOrder.shuffled(pool(40)));

    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 2});
    await PoolOrder.load();
    final String b = order(PoolOrder.shuffled(pool(40)));

    expect(a, isNot(b), reason: 'the whole point is that they disagree');
  });

  test('the first servers tried differ, which is what spreads the load', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 7});
    await PoolOrder.load();
    final List<String> first = PoolOrder.shuffled(pool(60))
        .take(10)
        .map((ProxyNode n) => n.server)
        .toList();
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 99});
    await PoolOrder.load();
    final List<String> other = PoolOrder.shuffled(pool(60))
        .take(10)
        .map((ProxyNode n) => n.server)
        .toList();
    expect(first.toSet().intersection(other.toSet()).length, lessThan(10),
        reason: 'the sweep stops early, so only the head of the list matters');
  });

  test('one install keeps the same order across launches', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 42});
    await PoolOrder.load();
    final String once = order(PoolOrder.shuffled(pool(30)));
    await PoolOrder.load(); // as on the next launch
    expect(order(PoolOrder.shuffled(pool(30))), once,
        reason: 'a list that reorders on every open is its own problem');
  });

  test('a seed is created and kept when there is none', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await PoolOrder.load();
    expect(PoolOrder.seed, isNotNull);
    final int made = PoolOrder.seed!;
    await PoolOrder.load();
    expect(PoolOrder.seed, made, reason: 'a new seed every launch is no seed');
  });

  test('nothing to shuffle is returned untouched', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 5});
    await PoolOrder.load();
    expect(PoolOrder.shuffled(const <ProxyNode>[]), isEmpty);
    expect(PoolOrder.shuffled(pool(1)).length, 1);
  });

  test('every server survives the shuffle', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'nova.poolSeed': 3});
    await PoolOrder.load();
    final List<ProxyNode> input = pool(50);
    final List<ProxyNode> out = PoolOrder.shuffled(input);
    expect(out.length, input.length);
    expect(out.map((ProxyNode n) => n.server).toSet(),
        input.map((ProxyNode n) => n.server).toSet());
  });
}
