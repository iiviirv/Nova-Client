import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';

/// A subscription can ask for the SNI-block bypass on by default
/// (`nova.sniBlockBypass`), because the operator knows it sits behind a network
/// that blocks the domain. That is a default, not a lock.
///
/// The rule the refresh applies is `operatorWants && !hardenTlsUserSet`, so the
/// flag deciding it has to survive a restart. If it did not, every launch would
/// look like a user who had never chosen, and the bypass the user turned off
/// would come back on its own.
void main() {
  ProxyProfile sub() => ProxyProfile(
        id: 'a',
        name: 'Nova subscription',
        kind: ProxyKind.vless,
        uri: '',
        subscriptionUrl: 'https://example.com/sub',
      );

  test('a fresh subscription has made no decision', () {
    expect(sub().hardenTlsUserSet, isFalse);
    expect(sub().hardenTls, isFalse);
  });

  test('the user turning the switch off is remembered across a restart', () {
    // What the server list does when the user touches the switch.
    final ProxyProfile chosen =
        sub().copyWith(hardenTls: false, hardenTlsUserSet: true);
    final ProxyProfile reloaded =
        ProxyProfile.fromJson(chosen.toJson());
    expect(reloaded.hardenTlsUserSet, isTrue,
        reason: 'losing this re-applies the operator default every launch');
    expect(reloaded.hardenTls, isFalse);
    // And that is exactly what suppresses the operator default.
    const bool operatorWants = true;
    expect(operatorWants && !reloaded.hardenTlsUserSet, isFalse);
  });

  test('the user turning it on is remembered too', () {
    final ProxyProfile reloaded = ProxyProfile.fromJson(
        sub().copyWith(hardenTls: true, hardenTlsUserSet: true).toJson());
    expect(reloaded.hardenTls, isTrue);
    expect(reloaded.hardenTlsUserSet, isTrue);
  });

  test('an undecided subscription takes the operator default', () {
    final ProxyProfile reloaded = ProxyProfile.fromJson(sub().toJson());
    const bool operatorWants = true;
    expect(operatorWants && !reloaded.hardenTlsUserSet, isTrue);
  });

  test('both Telegram links survive a restart', () {
    final ProxyProfile p = sub().copyWith(
      telegramProxy: 'tg://proxy?server=a&port=1&secret=s',
      telegramProxyWeb: 'https://t.me/proxy?server=a&port=1&secret=s',
    );
    final ProxyProfile reloaded = ProxyProfile.fromJson(p.toJson());
    expect(reloaded.telegramProxy, startsWith('tg://'));
    expect(reloaded.telegramProxyWeb, startsWith('https://t.me/'));
  });
}
