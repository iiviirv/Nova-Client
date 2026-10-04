import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox_proxy_controller.dart';

/// The ladder a clean-IP profile climbs when it carries no traffic, and the
/// rule that the two rungs are never both up.
///
/// Asked for from the field: try ECH first, then the older SNI bypass. ECH
/// encrypts the name outright and is what still gets through where splitting
/// the handshake stopped working; the bypass remains the answer where ECH is
/// refused, which happens on Cloudflare hosts whose zone will not accept it.
void main() {
  ProxyProfile p({bool ech = false, bool harden = false}) => ProxyProfile(
        id: 'x',
        name: 'x',
        kind: ProxyKind.subscription,
        uri: 'https://example.com/sub',
        echSni: ech,
        hardenTls: harden,
      );

  // The real decision the escalation makes, not a restatement of it.
  ProxyProfile? next(ProxyProfile from) => nextBypassStep(from);

  test('a plain profile tries ECH first, not fragmentation', () {
    final ProxyProfile? n = next(p());
    expect(n!.echSni, isTrue);
    expect(n.hardenTls, isFalse,
        reason: 'fragmentation is the fallback, not the first thing to try');
  });

  test('a profile already on ECH falls back to the bypass', () {
    final ProxyProfile? n = next(p(ech: true));
    expect(n!.hardenTls, isTrue);
    expect(n.echSni, isFalse,
        reason: 'ECH suppresses fragmentation in the config, so leaving it on '
            'would show a bypass that is not running');
  });

  test('a profile already on the bypass has nothing left to try', () {
    expect(next(p(harden: true)), isNull,
        reason: 'escalating forever would reconnect forever');
  });

  test('the two are never both on, at any step of the ladder', () {
    ProxyProfile? cur = p();
    for (int i = 0; i < 4 && cur != null; i++) {
      expect(cur.echSni && cur.hardenTls, isFalse,
          reason: 'both up at step $i');
      cur = next(cur);
    }
  });
}
