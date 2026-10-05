import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/dns_https_record.dart';

/// Whatever this lookup returns becomes the ECH key, and whoever supplies the
/// key holds the private half of it: they can decrypt the inner ClientHello
/// and read the real server name. That is the one thing ECH exists to stop.
/// ECH also switches fragmentation off, so a forged key leaves the name more
/// exposed than running without ECH at all.
///
/// Before this was fixed, none of it was checked. A reply with the wrong
/// transaction id, no question echoed, and a record for an entirely different
/// name was accepted and cached for six hours. Off-path was enough, because
/// with no id check only the source port has to be guessed.
void main() {
  /// An answer a resolver would send, with every field a forger would want to
  /// get wrong left adjustable.
  Uint8List answer({
    required int id,
    required String qname,
    required List<int> ech,
    int questions = 1,
  }) {
    final List<int> out = <int>[];
    out.addAll(<int>[(id >> 8) & 0xFF, id & 0xFF, 0x81, 0x80]);
    out.addAll(<int>[0, questions]);
    out.addAll(<int>[0, 1]); // one answer
    out.addAll(<int>[0, 0, 0, 0]);
    int nameAt = 12;
    for (int q = 0; q < questions; q++) {
      nameAt = out.length;
      for (final String l in qname.split('.')) {
        out.add(l.length);
        out.addAll(utf8.encode(l));
      }
      out.add(0);
      out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1]);
    }
    // The answer names itself by pointer to the last question, or to offset 12
    // when there are no questions to point at.
    final int ptr = questions == 0 ? 12 : nameAt;
    out.addAll(<int>[0xC0 | ((ptr >> 8) & 0x3F), ptr & 0xFF]);
    out.addAll(<int>[0, DnsHttpsRecord.kTypeHttps, 0, 1, 0, 0, 0, 60]);
    final List<int> body = <int>[
      0, 1, // priority
      0, // target: root
      0, DnsHttpsRecord.kParamEch,
      (ech.length >> 8) & 0xFF, ech.length & 0xFF,
      ...ech,
    ];
    out.addAll(<int>[(body.length >> 8) & 0xFF, body.length & 0xFF]);
    out.addAll(body);
    return Uint8List.fromList(out);
  }

  final List<int> real = utf8.encode('REAL-CLOUDFLARE-KEY');
  final List<int> forged = utf8.encode('ATTACKER-CONTROLLED-KEY');

  group('the parser refuses an answer to a question it did not ask', () {
    test('a reply carrying someone else transaction id is not the answer', () {
      final Uint8List a =
          answer(id: 0xBEEF, qname: 'cloudflare-ech.com', ech: forged);
      expect(
          DnsHttpsRecord.parseWireAnswer(a,
              expectId: 0x1234, expectName: 'cloudflare-ech.com'),
          isNull);
      // Same bytes, asked for under its own id: fine. This is what keeps the
      // test honest about WHY it rejected.
      expect(
          DnsHttpsRecord.parseWireAnswer(a,
              expectId: 0xBEEF, expectName: 'cloudflare-ech.com'),
          base64.encode(forged));
    });

    test('a reply about a different name is not the answer', () {
      final Uint8List a =
          answer(id: 0x1234, qname: 'evil.example', ech: forged);
      expect(
          DnsHttpsRecord.parseWireAnswer(a,
              expectId: 0x1234, expectName: 'cloudflare-ech.com'),
          isNull);
    });

    test('a reply that echoes no question at all is not the answer', () {
      final Uint8List a = answer(
          id: 0x1234, qname: 'cloudflare-ech.com', ech: forged, questions: 0);
      expect(
          DnsHttpsRecord.parseWireAnswer(a,
              expectId: 0x1234, expectName: 'cloudflare-ech.com'),
          isNull);
    });

    test('the real answer still reads, and names compare without case or root dot',
        () {
      final Uint8List a =
          answer(id: 0x1234, qname: 'Cloudflare-ECH.com', ech: real);
      expect(
          DnsHttpsRecord.parseWireAnswer(a,
              expectId: 0x1234, expectName: 'cloudflare-ech.com.'),
          base64.encode(real));
    });
  });

  group('over a real socket', () {
    test('a forged datagram from another port loses to the real answer',
        () async {
      final RawDatagramSocket server =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final RawDatagramSocket forger =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      int? askedId;
      final Completer<void> asked = Completer<void>();
      server.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = server.receive();
        if (d == null) return;
        askedId = (d.data[0] << 8) | d.data[1];
        if (!asked.isCompleted) asked.complete();
        // The forger gets in first, from a port the client never asked.
        forger.send(
            answer(id: askedId!, qname: 'cloudflare-ech.com', ech: forged),
            d.address,
            d.port);
        // The honest resolver answers from the socket that was queried.
        server.send(
            answer(id: askedId!, qname: 'cloudflare-ech.com', ech: real),
            d.address,
            d.port);
      });
      try {
        final String? got = await DnsHttpsRecord.lookup(
            'cloudflare-ech.com', 'udp://127.0.0.1:${server.port}',
            timeout: const Duration(seconds: 5));
        await asked.future;
        expect(got, base64.encode(real),
            reason: 'the answer must come from the server that was asked');
        expect(got, isNot(base64.encode(forged)));
      } finally {
        server.close();
        forger.close();
      }
    });

    test('a wrong-id reply from the right server does not settle the lookup',
        () async {
      final RawDatagramSocket server =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = server.receive();
        if (d == null) return;
        final int id = (d.data[0] << 8) | d.data[1];
        // Wrong id first. Completing on it would let one forgery deny the
        // real answer that is still in flight.
        server.send(
            answer(
                id: (id + 1) & 0xFFFF,
                qname: 'cloudflare-ech.com',
                ech: forged),
            d.address,
            d.port);
        server.send(answer(id: id, qname: 'cloudflare-ech.com', ech: real),
            d.address, d.port);
      });
      try {
        expect(
            await DnsHttpsRecord.lookup(
                'cloudflare-ech.com', 'udp://127.0.0.1:${server.port}',
                timeout: const Duration(seconds: 5)),
            base64.encode(real));
      } finally {
        server.close();
      }
    });

    test('only forgeries: the lookup reports nothing rather than a bad key',
        () async {
      final RawDatagramSocket server =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((RawSocketEvent e) {
        if (e != RawSocketEvent.read) return;
        final Datagram? d = server.receive();
        if (d == null) return;
        server.send(
            answer(id: 0xBEEF, qname: 'evil.example', ech: forged, questions: 0),
            d.address,
            d.port);
      });
      try {
        expect(
            await DnsHttpsRecord.lookup(
                'cloudflare-ech.com', 'udp://127.0.0.1:${server.port}',
                timeout: const Duration(seconds: 2)),
            isNull,
            reason: 'no key is safe; a forged key is not');
      } finally {
        server.close();
      }
    });
  });
}
