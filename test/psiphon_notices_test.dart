import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/psiphon/psiphon_notices.dart';

/// Readiness cannot come from the local port: Psiphon opens its SOCKS listener
/// before any tunnel exists, so a port check reports success while nothing can
/// reach the internet. That is the same shape as a dead WARP gateway looking
/// healthy, which cost weeks.
void main() {
  group('knowing when traffic can actually flow', () {
    test('a tunnel count above zero is the signal', () {
      expect(
          PsiphonNotices.tunnelIsUp(
              '{"noticeType":"Tunnels","data":{"count":1}}'),
          isTrue);
    });

    test('count zero means a tunnel went away, not that one arrived', () {
      expect(
          PsiphonNotices.tunnelIsUp(
              '{"noticeType":"Tunnels","data":{"count":0}}'),
          isFalse,
          reason: 'treating any Tunnels notice as ready calls a disconnection '
              'a connection');
    });

    test('the listener opening is not readiness', () {
      expect(
          PsiphonNotices.tunnelIsUp(
              '{"noticeType":"ListeningSocksProxyPort","data":{"port":1081}}'),
          isFalse,
          reason: 'this fires before any tunnel exists');
    });

    test('a panic or other non-JSON line is not readiness', () {
      expect(PsiphonNotices.tunnelIsUp('panic: runtime error'), isFalse);
      expect(PsiphonNotices.tunnelIsUp(''), isFalse);
      expect(PsiphonNotices.tunnelIsUp('{not json'), isFalse);
    });
  });

  group('what reaches the user log', () {
    test('an address is never written to a log people paste in public', () {
      final String? line = PsiphonNotices.forLog(
          '{"noticeType":"Warning","data":{"message":"rejecting in-proxy '
          'from country IR (IP: 203.0.113.44)"}}');
      expect(line, isNotNull);
      expect(line, isNot(contains('203.0.113.44')));
      expect(line, contains('[address removed]'));
    });

    test('IPv6 is scrubbed too', () {
      expect(PsiphonNotices.scrub('peer 2606:4700:100::1 refused'),
          isNot(contains('2606:4700')));
    });

    test('a Go panic is kept, because losing it hides a crash', () {
      expect(PsiphonNotices.forLog('panic: runtime error: index out of range'),
          contains('panic'));
    });

    test('engine chatter is dropped rather than flooding the log', () {
      expect(PsiphonNotices.forLog('{"noticeType":"BytesTransferred"}'), isNull);
    });

    test('a blank line is nothing', () {
      expect(PsiphonNotices.forLog('   '), isNull);
    });
  });
}
