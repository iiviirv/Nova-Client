import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';

/// Psiphon cannot reach its own network from inside Iran unaided, so the WARP
/// tunnel underneath it is the part that has to work. Field report,
/// 2026-10-09: MASQUE over HTTP/2 connects on nearly every ISP on both Iranian
/// firewalls, while the WireGuard modes connect only where nothing is blocked.
///
/// Picking whichever carrier happened to be stored first could therefore choose
/// the one that cannot work on the network in front of it, and the Psiphon
/// profile would fail for a reason that has nothing to do with Psiphon.
void main() {
  ProxyProfile carrier(String name, AetherMode mode) => ProxyProfile(
        id: name,
        name: name,
        kind: ProxyKind.aether,
        uri: AetherConfig(options: AetherOptions(mode: mode), name: name)
            .toLink(),
      );

  test('a MASQUE carrier is preferred over a WireGuard one', () {
    final List<ProxyProfile> stored = <ProxyProfile>[
      carrier('wg one', AetherMode.wg),
      carrier('gool one', AetherMode.gool),
      carrier('masque one', AetherMode.masque),
    ];
    bool isMasque(ProxyProfile p) =>
        AetherConfig.parse(p.uri)?.options.mode == AetherMode.masque;
    final List<ProxyProfile> ordered = <ProxyProfile>[
      ...stored.where(isMasque),
      ...stored.where((ProxyProfile p) => !isMasque(p)),
    ];
    expect(ordered.first.name, 'masque one');
    expect(ordered.map((ProxyProfile p) => p.name).toList(),
        <String>['masque one', 'wg one', 'gool one'],
        reason: 'stable below the preference, so the stored order still '
            'decides between equals');
  });

  /// Both controllers resolve a Psiphon carrier, in two separate places. This
  /// pair has been fixed one at a time six times over, so the ordering goes
  /// into both or neither.
  test('both controllers prefer a MASQUE carrier', () {
    for (final String path in <String>[
      'lib/src/core/proxy/singbox_proxy_controller.dart',
      'lib/src/core/proxy/desktop_proxy_controller.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src, contains('AetherMode.masque'),
          reason: '$path does not look at the carrier mode at all, so it can '
              'hand Psiphon a WireGuard tunnel on a network that blocks it');
    }
  });

  test('the default carrier a user creates is one that connects', () {
    // A freshly added Aether config is what most people will have, so its
    // defaults decide what Psiphon rides on in practice.
    const AetherOptions o = AetherOptions();
    expect(o.mode, AetherMode.masque);
    expect(o.transport, AetherTransport.h2);
    expect(o.fragment, isFalse, reason: 'split TLS off');
    expect(o.masqueSni, 'www.cloudflare.com');
  });
}
