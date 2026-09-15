import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_core.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

/// Reading the Aether core's replies, and building what it is asked with.
///
/// The envelope is nested for long work: a poll returns its own {"ok": ...}
/// wrapping the job's {"ok": ...}. A failed scan therefore arrives inside a
/// successful poll, and code that reads only the outer flag calls it a success
/// and then has no endpoint to show for it.
void main() {
  _endpoints();
  _identityField();
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

    test('gool declares the WireGuard transport, with the mode alongside', () {
      // The core's transport enum is {WireGuard, Masque} with an unrecognised
      // value falling through to Masque, so "gool" there meant Masque: the
      // search swept MASQUE endpoints and the tunnel was a MASQUE tunnel.
      // Confirmed on a device, where a gool search returned the same 443
      // gateway as MASQUE while WireGuard returned a high port.
      final Map<String, dynamic> sc =
          dec(AetherPayloads.scan(const AetherOptions(mode: AetherMode.gool)));
      expect(sc['transport'], 'wg');
      expect(sc['mode'], 'gool');
      final Map<String, dynamic> tn = dec(AetherPayloads.tunnel(
          const AetherOptions(mode: AetherMode.gool),
          endpoint: '1.2.3.4:2408',
          socks: '127.0.0.1:1'));
      expect(tn['transport'], 'wg');
      expect(tn['mode'], 'gool');
    });

    test('the WireGuard modes never claim an HTTP transport', () {
      // Sending h3 with wg would have the config quietly do something other
      // than what its name says.
      for (final AetherMode m in <AetherMode>[AetherMode.wg, AetherMode.gool]) {
        final Map<String, dynamic> p =
            dec(AetherPayloads.scan(AetherOptions(mode: m)));
        expect(p['transport'], 'wg');
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

    test('an identity payload names a path prefix and the transport', () {
      // The core replied "missing field `path`" when this was omitted, which
      // is how the field was learned rather than guessed. It is a path PREFIX:
      // a device run returned path ".../aether-masque" for a base of
      // ".../aether", so the core appends the transport rather than treating
      // this as a directory.
      final Map<String, dynamic> p = dec(AetherPayloads.identity(
          const AetherOptions(), base: '/data/user/0/app/files/aether'));
      expect(p['path'], '/data/user/0/app/files/aether');
      expect(p['transport'], 'h3');
      expect(p.containsKey('socks'), isFalse,
          reason: 'opening an identity does not serve anything');
    });

    test('the identity follows the transport, not just the mode', () {
      expect(
          dec(AetherPayloads.identity(
              const AetherOptions(transport: AetherTransport.h2),
              base: '/x'))['transport'],
          'h2');
      expect(
          dec(AetherPayloads.identity(
              const AetherOptions(mode: AetherMode.wg), base: '/x'))['transport'],
          'wg');
    });

    test('a tunnel payload names the gateway it is told to dial', () {
      // The core requires `peer` here. Omitting it, as the first version did,
      // gets the call refused outright, which is the same class of mistake as
      // opening an identity without a path.
      final Map<String, dynamic> p = dec(AetherPayloads.tunnel(
          const AetherOptions(),
          endpoint: '162.159.198.1:443',
          socks: '127.0.0.1:19819'));
      expect(p['peer'], '162.159.198.1:443');
      expect(p['socks'], '127.0.0.1:19819');
    });

    test('a tunnel carries the mode, because transport cannot express gool', () {
      // The core's transport has two values, Masque and WireGuard, and anything
      // unrecognised becomes Masque. So "gool" parses as Masque, and a tunnel
      // told only the transport builds a plain MASQUE tunnel under a gool name:
      // it connects, which is why it reads as working, while not being what the
      // config says.
      final Map<String, dynamic> p = dec(AetherPayloads.tunnel(
          const AetherOptions(mode: AetherMode.gool),
          endpoint: '1.2.3.4:443',
          socks: '127.0.0.1:1'));
      expect(p['mode'], 'gool');
      expect(p['peer'], '1.2.3.4:443');
    });

    test('every mode is named in the tunnel payload', () {
      for (final AetherMode m in AetherMode.values) {
        final Map<String, dynamic> p = dec(AetherPayloads.tunnel(
            AetherOptions(mode: m), endpoint: '1.2.3.4:443', socks: '1.2.3.4:1'));
        expect(p['mode'], m.name, reason: '$m must reach the core');
      }
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

/// The identity handle key, pinned from a device run.
void _identityField() {
  test('the handle key is the one the core returns', () {
    // From a real first run: {identity: 2, summary: {...}, path: ..., ok: true}
    expect(kAetherIdentityField, 'identity');
  });
}

/// Turning what the core returns into what it accepts.
void _endpoints() {
  group('gateway addresses', () {
    test('a scan result object becomes ip:port', () {
      // The real shape, from a device run:
      // {ip: 162.159.198.1, port: 443, rtt_ms: 617}
      expect(
          AetherEndpoint.parse(<String, dynamic>{
            'ip': '162.159.198.1',
            'port': 443,
            'rtt_ms': 617,
          }),
          '162.159.198.1:443');
    });

    test('the stringified map is never produced', () {
      // What the bug looked like. The core refused this as "not an
      // address:port", and the same value went into the excluded list where it
      // matched nothing, so the retry kept finding the address it had just
      // rejected.
      final String? out = AetherEndpoint.parse(<String, dynamic>{
        'ip': '162.159.198.1',
        'port': 443,
        'rtt_ms': 617,
      });
      expect(out!.contains('{'), isFalse);
      expect(out.contains('rtt'), isFalse);
    });

    test('a string passes through unchanged', () {
      expect(AetherEndpoint.parse('1.2.3.4:443'), '1.2.3.4:443');
    });

    test('an IPv6 address is bracketed so the port is readable', () {
      expect(AetherEndpoint.parse(<String, dynamic>{
        'ip': '2606:4700:d0::a29f:c001',
        'port': 443,
      }), '[2606:4700:d0::a29f:c001]:443');
    });

    test('anything that is not an endpoint is null, not a broken string', () {
      expect(AetherEndpoint.parse(null), isNull);
      expect(AetherEndpoint.parse(''), isNull);
      expect(AetherEndpoint.parse(<String, dynamic>{'rtt_ms': 5}), isNull);
      expect(AetherEndpoint.parse(<String, dynamic>{'ip': '1.2.3.4'}), isNull);
      expect(AetherEndpoint.parse(42), isNull);
    });
  });
}
