import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

/// Reading the Aether core's replies, and building what it is asked with.
///
/// The envelope is nested for long work: a poll returns its own {"ok": ...}
/// wrapping the job's {"ok": ...}. A failed scan therefore arrives inside a
/// successful poll, and code that reads only the outer flag calls it a success
/// and then has no endpoint to show for it.
void main() {
  group('replies', () {
    test('a success carries its fields', () {
      final AetherReply r = AetherReply.parse('{"ok":true,"job":7}');
      expect(r.ok, isTrue);
      expect(r['job'], 7);
      expect(r.error, isNull);
    });

    test('a failure carries the reason', () {
      final AetherReply r =
          AetherReply.parse('{"ok":false,"error":"no identity"}');
      expect(r.ok, isFalse);
      expect(r.error, 'no identity');
    });

    test('nothing, or nonsense, is an error rather than a crash', () {
      // These arrive from a native call in a UI path. A thrown exception here
      // is a blank screen; an error is something to show.
      for (final String? bad in <String?>[null, '', '   ', 'not json', '[1,2]']) {
        final AetherReply r = AetherReply.parse(bad);
        expect(r.ok, isFalse);
        expect(r.error, isNotNull);
      }
    });

    test('a reply with no ok field is not treated as success', () {
      expect(AetherReply.parse('{"job":7}').ok, isFalse);
    });
  });

  group('jobs', () {
    test('running', () {
      final AetherJobStatus s =
          AetherJobStatus.parse('{"ok":true,"state":"running"}');
      expect(s.isRunning, isTrue);
      expect(s.state, AetherJobState.running);
    });

    test('done, and the job worked', () {
      final AetherJobStatus s = AetherJobStatus.parse(
          '{"ok":true,"state":"done","result":{"ok":true,"endpoint":"162.159.198.1:443"}}');
      expect(s.state, AetherJobState.done);
      expect(s.result!['endpoint'], '162.159.198.1:443');
      expect(s.error, isNull);
    });

    test('done, but the job FAILED inside a successful poll', () {
      // The trap. The outer envelope says ok:true because the poll itself
      // worked. Only the inner one knows the scan found nothing.
      final AetherJobStatus s = AetherJobStatus.parse(
          '{"ok":true,"state":"done","result":{"ok":false,"error":"no gateway answered"}}');
      expect(s.state, AetherJobState.failed,
          reason: 'reading only the outer ok would call this a success');
      expect(s.error, 'no gateway answered');
      expect(s.result, isNull);
    });

    test('the poll itself failing is also a failure', () {
      final AetherJobStatus s =
          AetherJobStatus.parse('{"ok":false,"error":"there is no job 9"}');
      expect(s.state, AetherJobState.failed);
      expect(s.error, 'there is no job 9');
    });

    test('a done job with no result is a failure, not a silent success', () {
      final AetherJobStatus s =
          AetherJobStatus.parse('{"ok":true,"state":"done"}');
      expect(s.state, AetherJobState.failed);
      expect(s.error, isNotNull);
    });
  });

  group('payloads', () {
    Map<String, dynamic> dec(String s) =>
        jsonDecode(s) as Map<String, dynamic>;

    test('MASQUE names its HTTP transport', () {
      expect(dec(AetherPayloads.scan(const AetherOptions()))['transport'], 'h3');
      expect(
          dec(AetherPayloads.scan(
              const AetherOptions(transport: AetherTransport.h2)))['transport'],
          'h2');
    });

    test('the WireGuard modes never claim an HTTP transport', () {
      // Sending h3 with wg would have the config quietly do something other
      // than what its name says.
      for (final AetherMode m in <AetherMode>[AetherMode.wg, AetherMode.gool]) {
        final Map<String, dynamic> p =
            dec(AetherPayloads.scan(AetherOptions(mode: m)));
        expect(p['transport'], m.name);
        expect(p['transport'] == 'h3' || p['transport'] == 'h2', isFalse);
      }
    });

    test('excluded endpoints are sent, which is what makes a retry a retry', () {
      final Map<String, dynamic> p = dec(AetherPayloads.scan(
          const AetherOptions(),
          excluded: <String>['162.159.198.1:443']));
      expect(p['excluded'], <String>['162.159.198.1:443']);
    });

    test('no excluded key when there is nothing to exclude', () {
      expect(dec(AetherPayloads.scan(const AetherOptions()))
          .containsKey('excluded'), isFalse);
    });

    test('a tunnel payload carries the local socks address', () {
      final Map<String, dynamic> p = dec(AetherPayloads.tunnel(
          const AetherOptions(), socks: '127.0.0.1:19819'));
      expect(p['socks'], '127.0.0.1:19819');
    });

    test('the obfuscation profile is omitted when unset', () {
      expect(dec(AetherPayloads.scan(const AetherOptions()))
          .containsKey('profile'), isFalse);
      expect(
          dec(AetherPayloads.scan(
              const AetherOptions(noize: AetherNoize.gfw)))['profile'],
          'gfw');
    });
  });
}
