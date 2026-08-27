import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// A `target=nova` subscription can advertise a Telegram proxy alongside the
/// servers. It is not a Nova exit and nothing connects to it; it is a link the
/// user can hand to Telegram, so the client's only job is to find it and offer
/// it. A user reported seeing it in the subscription but nowhere in the app.
void main() {
  String body(String inner) => '{"outbounds":[],"nova":{$inner}}';

  test('reads the t.me form in preference to the tg:// one', () {
    final String? url = parseNovaTelegramProxy(body(
        '"telegramProxy":{"tme":"https://t.me/proxy?server=a&port=1&secret=s",'
        '"tg":"tg://proxy?server=a&port=1&secret=s"}'));
    expect(url, 'https://t.me/proxy?server=a&port=1&secret=s');
  });

  test('falls back to the tg:// form when that is all there is', () {
    final String? url = parseNovaTelegramProxy(
        body('"telegramProxy":{"tg":"tg://proxy?server=a&port=1&secret=s"}'));
    expect(url, 'tg://proxy?server=a&port=1&secret=s');
  });

  test('assembles one from the parts when neither link is given', () {
    final String? url = parseNovaTelegramProxy(body(
        '"telegramProxy":{"server":"vpn.example.com","port":2053,"secret":"ab"}'));
    expect(url, 'https://t.me/proxy?server=vpn.example.com&port=2053&secret=ab');
  });

  test('a subscription with no Telegram proxy yields null, not an error', () {
    expect(parseNovaTelegramProxy('{"outbounds":[]}'), isNull);
    expect(parseNovaTelegramProxy(body('"somethingElse":1')), isNull);
  });

  test('a link-list subscription is not JSON and must not throw', () {
    expect(parseNovaTelegramProxy('vless://x@a:1?type=ws\ntrojan://y@b:2'), isNull);
    expect(parseNovaTelegramProxy(''), isNull);
  });

  test('parsing a body sets the side channel, and clears it for one without',
      () {
    parseSubscriptionBody(body(
        '"telegramProxy":{"tme":"https://t.me/proxy?server=a&port=1&secret=s"}'));
    expect(lastTelegramProxy, 'https://t.me/proxy?server=a&port=1&secret=s');
    // A later subscription with none must not inherit the previous one's link.
    parseSubscriptionBody('vless://x@a:1?type=ws');
    expect(lastTelegramProxy, isNull);
  });
}
