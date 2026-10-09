import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';
import 'package:nova_client/src/core/proxy/aether/aether_gateway_finder.dart';
import 'package:nova_client/src/features/servers/aether_gateway_search.dart';

/// Aether compiles the MASQUE server name in as a constant,
/// `consumer-masque.cloudflareclient.com`, and its own help text says what that
/// costs: "Iran's firewall resets a whole ClientHello whose SNI ends in
/// cloudflareclient.com". Upstream answers by fragmenting the hello so the name
/// straddles a packet boundary. This is the other answer, measured working in
/// the field on 2026-10-09 with fragmentation switched off: send a name the
/// filter has no reason to match.
///
/// Needs Nova's patched core. Upstream has no such flag, no such environment
/// variable, and no `sni` in its FFI payloads; I checked the published source
/// and the shipped binaries before writing this.
void main() {
  Map<String, dynamic> tunnelOf(AetherOptions o) =>
      jsonDecode(AetherPayloads.tunnel(o, endpoint: '1.2.3.4:443', socks: '127.0.0.1:1080'))
          as Map<String, dynamic>;
  Map<String, dynamic> scanOf(AetherOptions o) =>
      jsonDecode(AetherPayloads.scan(o)) as Map<String, dynamic>;

  group('what reaches the core', () {
    test('a MASQUE job carries the name, on both transports', () {
      for (final AetherTransport t in AetherTransport.values) {
        final AetherOptions o = AetherOptions(transport: t);
        expect(tunnelOf(o)['sni'], 'www.cloudflare.com', reason: 'transport $t');
        expect(scanOf(o)['sni'], 'www.cloudflare.com', reason: 'transport $t');
      }
    });

    test('a WireGuard job carries no name at all', () {
      const AetherOptions o = AetherOptions(mode: AetherMode.wg);
      expect(tunnelOf(o).containsKey('sni'), isFalse,
          reason: 'there is no TLS handshake there to put a name in');
      expect(scanOf(o).containsKey('sni'), isFalse);
    });

    test('blank means the core keeps its own name', () {
      for (final String blank in <String>['', '   ']) {
        final AetherOptions o = AetherOptions(masqueSni: blank);
        expect(tunnelOf(o).containsKey('sni'), isFalse,
            reason: 'an empty SNI is a different thing from no SNI: Cloudflare '
                'serves a self-signed cert for a name it does not recognise');
      }
    });

    test('a name typed with stray spaces is trimmed, not sent as typed', () {
      const AetherOptions o = AetherOptions(masqueSni: '  example.com  ');
      expect(tunnelOf(o)['sni'], 'example.com');
    });
  });

  group('the link round-trips', () {
    test('the default is not written out, so shared links stay compatible', () {
      const AetherOptions o = AetherOptions();
      expect(o.toQuery(), isNot(contains('sni=')),
          reason: 'a config shared out of Nova has to import into the other '
              'clients byte for byte');
      expect(AetherOptions.fromQuery(o.toQuery()).masqueSni,
          kAetherDefaultMasqueSni);
    });

    test('a chosen name survives a round trip', () {
      const AetherOptions o = AetherOptions(masqueSni: 'cdn.example.org');
      expect(o.toQuery(), contains('sni=cdn.example.org'));
      expect(AetherOptions.fromQuery(o.toQuery()).masqueSni, 'cdn.example.org');
    });

    test('an older link with no sni gets the new default, not a blank', () {
      expect(AetherOptions.fromQuery('protocol=masque&ip=v4').masqueSni,
          kAetherDefaultMasqueSni);
    });

    /// The name is an FFI field, not a command-line flag. pattNG's editor shows
    /// `--masque-sni` because pattNG runs the binary; Nova drives the core
    /// through its FFI, and the patch adds the field to the payloads without
    /// touching the core's argument parser. Emitting the flag here would put a
    /// value in Nova's command preview that the binary would refuse, which is
    /// what aether_options_test's "every emitted value is one the binary lists"
    /// caught when this method briefly did emit it.
    test('the name is not a command-line flag, because the core has none', () {
      for (final AetherOptions o in <AetherOptions>[
        const AetherOptions(),
        const AetherOptions(masqueSni: 'cdn.example.org'),
        const AetherOptions(mode: AetherMode.wg),
      ]) {
        expect(o.toCliArgs().join(' '), isNot(contains('masque-sni')));
        expect(o.toCliArgs().join(' '), isNot(contains('cdn.example.org')));
      }
    });
  });

  /// Two phases, two answers to the same problem. The second is exactly what
  /// Nova did before the name was settable, so a network the new name does not
  /// suit is no worse off than it was.
  group('the fallback ladder', () {
    test('the second phase asks for the core own name and fragments it',
        () async {
      final List<AetherOptions> seen = <AetherOptions>[];
      final AetherAdaptiveSearch search = AetherAdaptiveSearch(
        createSearch: () => _Recording(seen),
        fallbackAfter: const Duration(milliseconds: 50),
      );
      await search.run(const AetherOptions(), (_) {});
      expect(seen.length, 2, reason: 'one scan, then the fallback');
      expect(seen.first.masqueSni, kAetherDefaultMasqueSni);
      expect(seen.first.fragment, isFalse,
          reason: 'the whole point is to leave the hello in one piece');
      expect(seen.last.masqueSni, kAetherStockMasqueSni);
      expect(seen.last.fragment, isTrue);
      expect(seen.last.transport, AetherTransport.h2);
    });
  });
}

/// Records what it was asked to scan for and never finds anything, so the
/// ladder always reaches its second phase.
class _Recording implements AetherGatewaySearch {
  _Recording(this.seen);
  final List<AetherOptions> seen;
  @override
  bool get available => true;
  @override
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  Future<bool> verifyAddress(AetherOptions options, String endpoint) async =>
      false;
  @override
  Future<AetherFindResult> run(
      AetherOptions options, ValueChanged<AetherSearchProgress> onProgress,
      {List<String> excludedFirst = const <String>[]}) async {
    seen.add(options);
    onProgress(const AetherSearchProgress(
        attempt: 1, verifying: false, ruledOut: 0));
    return const AetherFindResult(
        endpoint: null, attempts: 1, rejected: <String>[], error: 'none');
  }
}
