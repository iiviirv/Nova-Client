import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// Two clean-IP fronted nodes on the same worker, different edge IPs, exactly
/// the shape the SNI-block bypass is for. Their keys are what the core's per-node
/// latency has to be attributed to.
ProxyNode _node(String ip) => parseShareLink(
      'vless://00000000-0000-4000-8000-000000000000@$ip:2053'
      '?encryption=none&security=tls&sni=azure-fox.altramax083.workers.dev'
      '&type=ws&host=azure-fox.altramax083.workers.dev&path=%2Fp#N-$ip',
    )!;

void main() {
  group('tag <-> node mapping for the auto-select pool', () {
    test('orderedMultiNodeKeys lines up with the node-i tags the config emits',
        () {
      final List<ProxyNode> nodes = <ProxyNode>[
        _node('172.67.70.1'),
        _node('104.16.0.2'),
        _node('188.114.96.3'),
      ];
      final List<String> keys = SingboxConfig.orderedMultiNodeKeys(nodes);
      expect(keys.length, 3);
      // node-0 is the first picked node, and so on: this is the contract the
      // controller relies on to attribute the core's numbers.
      for (int i = 0; i < nodes.length; i++) {
        expect(keys[i], proxyNodeKey(nodes[i]),
            reason: 'node-$i must map to the i-th node');
      }
    });

    test('a single node has no urltest group, so no tag keys', () {
      expect(SingboxConfig.orderedMultiNodeKeys(<ProxyNode>[_node('1.2.3.4')]),
          isEmpty);
    });
  });

  group('parsing the core groups payload', () {
    final Map<String, String> tagKeys = <String, String>{
      'node-0': 'k0',
      'node-1': 'k1',
      'node-2': 'k2',
    };

    test('maps node-i delays to keys, marks the selected one', () {
      final CoreNodeHealth h = SingboxProxyController.parseCoreGroups(
        tagKeys,
        <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'selected': 'node-1',
            'items': <dynamic>[
              <String, dynamic>{'tag': 'node-0', 'delay': 210},
              <String, dynamic>{'tag': 'node-1', 'delay': 175},
              <String, dynamic>{'tag': 'node-2', 'delay': 340},
            ],
          },
        ],
      );
      expect(h.delayMsByKey, <String, int>{'k0': 210, 'k1': 175, 'k2': 340});
      expect(h.selectedKey, 'k1');
    });

    test('a 0 delay (no successful test yet) is dropped, not shown as 0 ms', () {
      final CoreNodeHealth h = SingboxProxyController.parseCoreGroups(
        tagKeys,
        <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'selected': 'node-0',
            'items': <dynamic>[
              <String, dynamic>{'tag': 'node-0', 'delay': 190},
              <String, dynamic>{'tag': 'node-1', 'delay': 0},
            ],
          },
        ],
      );
      expect(h.delayMsByKey.containsKey('k1'), isFalse);
      expect(h.delayMsByKey['k0'], 190);
    });

    test('groups other than the auto-selector are ignored', () {
      final CoreNodeHealth h = SingboxProxyController.parseCoreGroups(
        tagKeys,
        <dynamic>[
          <String, dynamic>{
            'tag': 'some-selector',
            'selected': 'node-2',
            'items': <dynamic>[
              <String, dynamic>{'tag': 'node-2', 'delay': 99},
            ],
          },
        ],
      );
      expect(h.isEmpty, isTrue,
          reason: 'only the proxy urltest group is a source of truth');
    });

    test('unknown tags (a node no longer in the pool) are skipped', () {
      final CoreNodeHealth h = SingboxProxyController.parseCoreGroups(
        tagKeys,
        <dynamic>[
          <String, dynamic>{
            'tag': 'proxy',
            'selected': 'node-9',
            'items': <dynamic>[
              <String, dynamic>{'tag': 'node-9', 'delay': 120},
              <String, dynamic>{'tag': 'node-0', 'delay': 200},
            ],
          },
        ],
      );
      expect(h.delayMsByKey, <String, int>{'k0': 200});
      expect(h.selectedKey, isNull, reason: 'node-9 maps to nothing');
    });

    test('a malformed payload is empty, never a throw', () {
      expect(SingboxProxyController.parseCoreGroups(tagKeys, null).isEmpty,
          isTrue);
      expect(SingboxProxyController.parseCoreGroups(tagKeys, 'nonsense').isEmpty,
          isTrue);
    });
  });

  group('CoreNodeHealth lookups by node', () {
    test('delayFor and isSelected resolve through proxyNodeKey', () {
      final ProxyNode a = _node('172.67.70.1');
      final ProxyNode b = _node('104.16.0.2');
      final CoreNodeHealth h = CoreNodeHealth(
        delayMsByKey: <String, int>{proxyNodeKey(a): 150},
        selectedKey: proxyNodeKey(a),
      );
      expect(h.delayFor(a), 150);
      expect(h.delayFor(b), isNull);
      expect(h.isSelected(a), isTrue);
      expect(h.isSelected(b), isFalse);
    });
  });
}
