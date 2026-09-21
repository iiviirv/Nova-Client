import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_options.dart';
import 'package:nova_client/src/core/proxy/aether/aether_protocol.dart';

void main() {
  test('custom fragment settings survive links copy and scan/tunnel payloads',
      () {
    const o = AetherOptions(
        transport: AetherTransport.h2,
        fragment: true,
        fragmentSize: '18-28',
        fragmentDelay: '3-9');
    final read = AetherConfig.parse(const AetherConfig(options: o).toLink())!
        .options
        .copyWith(peer: '1.2.3.4:443');
    expect(read.fragmentSize, '18-28');
    expect(read.fragmentDelay, '3-9');
    for (final raw in [
      AetherPayloads.scan(read),
      AetherPayloads.tunnel(read,
          endpoint: '1.2.3.4:443', socks: '127.0.0.1:9999')
    ]) {
      final p = jsonDecode(raw) as Map<String, dynamic>;
      expect(p['transport'], 'h2');
      expect(p['fragment'], true);
      expect(p['fragment_size'], '18-28');
      expect(p['fragment_delay'], '3-9');
    }
    expect(
        read.toCliArgs(),
        containsAllInOrder([
          '--h2',
          '--fragment',
          '--fragment-size',
          '18-28',
          '--fragment-delay',
          '3-9'
        ]));
  });
  test('fragment validation rejects malformed reversed and excessive ranges',
      () {
    for (final s in [
      '0',
      '32-16',
      '1-16385',
      '1-2-3',
      '-2',
      'abc',
      '999999999999999999999999999999'
    ]) {
      expect(AetherOptions.validFragmentRange(s, delay: false), false,
          reason: s);
    }
    expect(AetherOptions.validFragmentRange('0', delay: true), true);
    expect(AetherOptions.validFragmentRange('2-10', delay: true), true);
    expect(AetherOptions.validFragmentRange('1001', delay: true), false);
    const o = AetherOptions(fragmentSize: 'bad', fragmentDelay: '-2');
    expect(o.effectiveFragmentSize, '16-32');
    expect(o.effectiveFragmentDelay, '2-10');
  });
  test('HTTP3 and WireGuard never receive TLS fragment fields', () {
    for (final o in [
      const AetherOptions(fragment: true),
      const AetherOptions(
          mode: AetherMode.wg, transport: AetherTransport.h2, fragment: true)
    ]) {
      expect(jsonDecode(AetherPayloads.scan(o)), isNot(contains('fragment')));
      expect(
          jsonDecode(AetherPayloads.tunnel(o,
              endpoint: '1.2.3.4:443', socks: '127.0.0.1:9999')),
          isNot(contains('fragment')));
    }
  });
}
