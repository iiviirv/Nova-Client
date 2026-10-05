import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/dns_https_record.dart';

/// The ECH lookup is now editable in the form other clients use, and that form
/// names a transport: `udp://1.0.0.1` asks for UDP. Accepting the text and
/// quietly doing DNS-over-HTTPS instead would be a setting that lies, so Nova
/// speaks all three. The wire format is parsed here rather than trusted,
/// because a wrong answer means a key that does not decrypt, which fails every
/// connection on the profile rather than degrading.
void main() {
  group('the query it sends', () {
    test('asks for the HTTPS record of the right name', () {
      final Uint8List q = DnsHttpsRecord.buildQuery('cloudflare-ech.com', id: 0x1234);
      expect(q[0], 0x12);
      expect(q[1], 0x34);
      expect((q[2] << 8) | q[3], 0x0100, reason: 'recursion desired');
      expect((q[4] << 8) | q[5], 1, reason: 'exactly one question');
      // The name, length-prefixed label by label.
      expect(q.sublist(12, 13).first, 'cloudflare-ech'.length);
      expect(utf8.decode(q.sublist(13, 13 + 14)), 'cloudflare-ech');
      // Then type HTTPS (65) and class IN (1).
      final int typeAt = q.length - 4;
      expect((q[typeAt] << 8) | q[typeAt + 1], DnsHttpsRecord.kTypeHttps);
      expect((q[typeAt + 2] << 8) | q[typeAt + 3], 1);
    });

    test('a label too long is refused rather than truncated', () {
      expect(() => DnsHttpsRecord.buildQuery('${'a' * 64}.com'),
          throwsA(isA<FormatException>()));
    });
  });

  group('the answer it reads', () {
    /// A minimal HTTPS answer carrying SvcParam 5, built the way a resolver
    /// would, so the parser is tested against the format and not against
    /// itself.
    Uint8List answer(List<int> echValue) {
      final List<int> out = <int>[];
      out.addAll(<int>[0x12, 0x34, 0x81, 0x80]);
      out.addAll(<int>[0, 1]); // one question
      out.addAll(<int>[0, 1]); // one answer
      out.addAll(<int>[0, 0, 0, 0]);
      for (final String l in <String>['test', 'com']) {
        out.add(l.length);
        out.addAll(utf8.encode(l));
      }
      out.add(0);
      out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1]);
      // Answer: a compression pointer to the question name.
      out.addAll(<int>[0xC0, 0x0C]);
      out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1, 0, 0, 0, 60]);
      final List<int> body = <int>[
        0, 1, // priority
        0, // target: root
        0, DnsHttpsRecord.kParamEch,
        (echValue.length >> 8) & 0xFF, echValue.length & 0xFF,
        ...echValue,
      ];
      out.addAll(<int>[(body.length >> 8) & 0xFF, body.length & 0xFF]);
      out.addAll(body);
      return Uint8List.fromList(out);
    }

    test('the ech parameter comes back base64, as a config wants it', () {
      final List<int> raw = <int>[0, 0x45, 0xFE, 0x0D, 0x41, 0x0A];
      expect(DnsHttpsRecord.parseWireAnswer(answer(raw)), base64.encode(raw));
    });

    test('a record without an ech parameter is not invented', () {
      final Uint8List a = answer(<int>[1, 2, 3]);
      // Flip the SvcParamKey from 5 to 1 (alpn): same shape, no ech.
      final int at = a.lastIndexOf(DnsHttpsRecord.kParamEch);
      a[at] = 1;
      expect(DnsHttpsRecord.parseWireAnswer(a), isNull);
    });

    test('a truncated or empty message is survived, not crashed on', () {
      expect(DnsHttpsRecord.parseWireAnswer(Uint8List(0)), isNull);
      expect(DnsHttpsRecord.parseWireAnswer(Uint8List(11)), isNull);
      final Uint8List a = answer(<int>[1, 2, 3]);
      expect(DnsHttpsRecord.parseWireAnswer(a.sublist(0, a.length - 4)), isNull);
    });

    test('an answer with no answers at all is null', () {
      final Uint8List a = answer(<int>[1, 2, 3]);
      a[6] = 0;
      a[7] = 0;
      expect(DnsHttpsRecord.parseWireAnswer(a), isNull);
    });
  });

  group('the DoH answer it reads', () {
    test('the ech value is picked out', () {
      expect(
          DnsHttpsRecord.parseJsonAnswer(
              '{"Answer":[{"type":65,"data":"1 . alpn=h2 ech=ABCD= ipv4hint=1.2.3.4"}]}'),
          'ABCD=');
    });

    test('a quoted value is unquoted, because some providers quote it', () {
      // Measured: NextDNS and doh.sb return ech="AEX..." where Cloudflare and
      // Google return it bare. A key with a stray quote is refused exactly like
      // a stale one, and just as silently.
      expect(
          DnsHttpsRecord.parseJsonAnswer(
              '{"Answer":[{"type":65,"data":"1 . ech=\\"ABCD=\\" alpn=h2"}]}'),
          'ABCD=');
    });

    test('a quote that is not a pair is left alone', () {
      expect(
          DnsHttpsRecord.parseJsonAnswer(
              '{"Answer":[{"type":65,"data":"1 . ech=\\"ABCD="}]}'),
          '"ABCD=');
    });

    test('nothing is invented when there is none', () {
      expect(DnsHttpsRecord.parseJsonAnswer('{"Answer":[{"data":"1 . alpn=h2"}]}'),
          isNull);
      expect(DnsHttpsRecord.parseJsonAnswer('{}'), isNull);
      expect(DnsHttpsRecord.parseJsonAnswer('nonsense'), isNull);
    });
  });

  test('an unknown resolver scheme is refused rather than guessed at', () async {
    expect(await DnsHttpsRecord.lookup('example.com', 'ftp://1.1.1.1'), isNull);
    expect(await DnsHttpsRecord.lookup('example.com', ''), isNull);
  });

  group('the transport it was asked for is the transport it uses', () {
    /// Answers one DNS query on loopback with [ech], so the UDP and TCP paths
    /// can be proven without the internet. The point is not the parsing, which
    /// is covered above, but that `udp://` really sends a datagram: a lookup
    /// that quietly used DoH instead would be a setting that lies, and nothing
    /// offline would have noticed.
    Future<(int port, Future<void> done)> udpResponder(List<int> ech) async {
      final RawDatagramSocket sock =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final Completer<void> served = Completer<void>();
      sock.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = sock.receive();
        if (d == null) return;
        final List<int> q = d.data;
        // Echo the query id and question back, then one HTTPS answer.
        final List<int> out = <int>[q[0], q[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0];
        int i = 12;
        while (i < q.length && q[i] != 0) {
          i += 1 + q[i];
        }
        out.addAll(q.sublist(12, i + 1));
        out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1]);
        out.addAll(<int>[0xC0, 0x0C]);
        out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1, 0, 0, 0, 60]);
        final List<int> body = <int>[
          0, 1, 0,
          0, DnsHttpsRecord.kParamEch,
          (ech.length >> 8) & 0xFF, ech.length & 0xFF,
          ...ech,
        ];
        out.addAll(<int>[(body.length >> 8) & 0xFF, body.length & 0xFF]);
        out.addAll(body);
        sock.send(Uint8List.fromList(out), d.address, d.port);
        if (!served.isCompleted) served.complete();
      });
      return (sock.port, served.future.whenComplete(sock.close));
    }

    test('udp:// really asks over UDP, and the answer comes back', () async {
      final List<int> ech = <int>[0, 0x45, 0xFE, 0x0D, 0x41];
      final (int port, Future<void> done) = await udpResponder(ech);
      final String? got = await DnsHttpsRecord.lookup(
          'cloudflare-ech.com', 'udp://127.0.0.1:$port');
      expect(got, base64.encode(ech),
          reason: 'a lookup that quietly used DoH would never have reached '
              'this socket');
      await done;
    });

    test('a resolver that never answers times out rather than hanging',
        () async {
      final RawDatagramSocket dead =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        expect(
            await DnsHttpsRecord.lookup(
                'cloudflare-ech.com', 'udp://127.0.0.1:${dead.port}',
                timeout: const Duration(milliseconds: 300)),
            isNull);
      } finally {
        dead.close();
      }
    });
  });
}
