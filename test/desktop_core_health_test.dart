import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';

/// Desktop never fed [CoreNodeHealth], so nodes the outside probe cannot judge
/// (Reality, obfuscated Hysteria2, SS2022, xhttp) stayed "not testable" on
/// Windows/macOS even while the core was happily routing through them. The
/// desktop controller now reads the core's own per-node urltest results off the
/// Clash API and publishes them as the same [CoreNodeHealth] mobile streams.
///
/// The body below is the exact JSON the shipped sing-box core returned from
/// `GET /proxies` during development, so this guards the real shape, not a
/// paraphrase of it.
void main() {
  const Map<String, String> tagKeys = <String, String>{
    'node-0': 'de.example.net:443:/ws',
    'node-1': 'nl.example.net:443:/ws',
  };

  Map<String, dynamic> body({
    int? d0,
    int? d1,
    String? now = 'node-0',
  }) =>
      <String, dynamic>{
        'proxies': <String, dynamic>{
          'node-0': <String, dynamic>{
            'type': 'Direct',
            'history': d0 == null
                ? <dynamic>[]
                : <dynamic>[
                    <String, dynamic>{
                      'time': '2026-08-18T23:08:29.365859-04:00',
                      'delay': d0
                    }
                  ],
          },
          'node-1': <String, dynamic>{
            'type': 'Direct',
            'history': d1 == null
                ? <dynamic>[]
                : <dynamic>[
                    <String, dynamic>{
                      'time': '2026-08-18T23:08:29.425897-04:00',
                      'delay': d1
                    }
                  ],
          },
          'proxy': <String, dynamic>{
            'type': 'URLTest',
            'now': now,
            'all': <String>['node-0', 'node-1'],
          },
          'direct': <String, dynamic>{'type': 'Direct'},
        },
      };

  test('per-node delays land on the right server keys', () {
    final CoreNodeHealth h = DesktopProxyController.healthFromClashProxies(
        tagKeys, body(d0: 46, d1: 47));
    expect(h.delayMsByKey['de.example.net:443:/ws'], 46);
    expect(h.delayMsByKey['nl.example.net:443:/ws'], 47);
  });

  test('the urltest group\'s "now" becomes the selected key', () {
    final CoreNodeHealth h = DesktopProxyController.healthFromClashProxies(
        tagKeys, body(d0: 46, d1: 47, now: 'node-1'));
    expect(h.selectedKey, 'nl.example.net:443:/ws');
  });

  test('a node with no measurement yet is tested-but-no-answer, not a ping', () {
    // node-1 has empty history: the core tried the pool but this member has
    // not answered. It must not get a fake number, and it must not read as
    // "not testable" either: it is a real no-response.
    final CoreNodeHealth h = DesktopProxyController.healthFromClashProxies(
        tagKeys, body(d0: 46, d1: null));
    expect(h.delayMsByKey.containsKey('nl.example.net:443:/ws'), isFalse);
    expect(h.testedKeys, contains('nl.example.net:443:/ws'));
    expect(h.delayMsByKey['de.example.net:443:/ws'], 46);
  });

  test('tags outside the map (direct, the group itself) are ignored', () {
    final CoreNodeHealth h = DesktopProxyController.healthFromClashProxies(
        tagKeys, body(d0: 46, d1: 47));
    expect(h.delayMsByKey.keys, hasLength(2));
  });

  test('an empty tag map (single/pinned node) yields empty health', () {
    final CoreNodeHealth h = DesktopProxyController.healthFromClashProxies(
        const <String, String>{}, body(d0: 46, d1: 47));
    expect(h.isEmpty, isTrue);
  });
}
