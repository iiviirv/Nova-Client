import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// A `target=nova` subscription can advertise a Telegram proxy and an
/// SNI-block default alongside the servers.
///
/// Nova Server 1.72.0 renamed the proxy fields from `tg`/`tme` to
/// `url`/`webUrl`, with the old names removed rather than aliased. The rename
/// exists to fix a real mistake: `tme` only opens a web page showing a proxy
/// the reader cannot add, and Nova shipped it as the primary action. `url` is
/// the `tg://` link that hands the proxy to Telegram, and it is what must be
/// tapped first.
void main() {
  String body(String inner) => '{"outbounds":[],"nova":{$inner}}';

  group('telegram proxy', () {
    test('uses the app link, and keeps the web one only as a fallback', () {
      final TelegramProxy? p = parseNovaTelegramProxy(body(
          '"telegramProxy":{"url":"tg://proxy?server=a&port=1&secret=s",'
          '"webUrl":"https://t.me/proxy?server=a&port=1&secret=s"}'));
      expect(p!.url, startsWith('tg://'),
          reason: 'the web link must never be the primary action');
      expect(p.webUrl, startsWith('https://t.me/'));
    });

    test('still reads a pre-1.72.0 panel, which used tg/tme', () {
      final TelegramProxy? p = parseNovaTelegramProxy(body(
          '"telegramProxy":{"tg":"tg://proxy?server=a&port=1&secret=s",'
          '"tme":"https://t.me/proxy?server=a&port=1&secret=s"}'));
      expect(p!.url, startsWith('tg://'));
      expect(p.webUrl, startsWith('https://t.me/'));
    });

    test('builds the app link from the parts when no link is given', () {
      final TelegramProxy? p = parseNovaTelegramProxy(body(
          '"telegramProxy":{"server":"vpn.example.com","port":2053,"secret":"ab"}'));
      expect(p!.url, 'tg://proxy?server=vpn.example.com&port=2053&secret=ab');
      expect(p.webUrl,
          'https://t.me/proxy?server=vpn.example.com&port=2053&secret=ab');
    });

    test('a web link on its own is still offered rather than dropped', () {
      final TelegramProxy? p = parseNovaTelegramProxy(
          body('"telegramProxy":{"webUrl":"https://t.me/proxy?server=a"}'));
      expect(p!.url, startsWith('https://t.me/'));
    });

    test('no proxy, a link-list body, or junk all yield null', () {
      expect(parseNovaTelegramProxy('{"outbounds":[]}'), isNull);
      expect(parseNovaTelegramProxy(body('"somethingElse":1')), isNull);
      expect(parseNovaTelegramProxy('vless://x@a:1?type=ws'), isNull);
      expect(parseNovaTelegramProxy(''), isNull);
    });
  });

  group('sni block bypass', () {
    test('present and true means on', () {
      expect(parseNovaSniBlockBypass(body('"sniBlockBypass":true')), isTrue);
    });

    test('absent means off, which is how the server says off', () {
      expect(parseNovaSniBlockBypass(body('"telegramProxy":{}')), isFalse);
      expect(parseNovaSniBlockBypass('{"outbounds":[]}'), isFalse);
      expect(parseNovaSniBlockBypass('vless://x@a:1'), isFalse);
    });
  });

  test('parsing sets both side channels, and clears them for a plain body', () {
    parseSubscriptionBody(body(
        '"telegramProxy":{"url":"tg://proxy?server=a&port=1&secret=s"},'
        '"sniBlockBypass":true'));
    expect(lastTelegramProxy!.url, 'tg://proxy?server=a&port=1&secret=s');
    expect(lastSniBlockBypass, isTrue);
    // A later subscription with neither must not inherit the previous one's.
    parseSubscriptionBody('vless://x@a:1?type=ws');
    expect(lastTelegramProxy, isNull);
    expect(lastSniBlockBypass, isFalse);
  });
}
