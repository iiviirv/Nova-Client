import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/ech_spec.dart';

/// Asked for from the field: let the ECH lookup be edited the way other
/// clients spell it, `cloudflare-ech.com+udp://1.0.0.1`, so a setting that
/// works elsewhere can be pasted in rather than translated.
void main() {
  test('the default is Cloudflare over DoH, not the udp other clients use', () {
    expect(EchSpec.parse(null), EchSpec.fallback);
    expect(EchSpec.parse(''), EchSpec.fallback);
    expect(EchSpec.fallback.domain, 'cloudflare-ech.com');
    expect(EchSpec.fallback.resolver, 'udp://1.1.1.1',
        reason: 'the default was DoH on my assumption that UDP to Cloudflare '
            'was blocked. The tester had said otherwise from the first report: '
            'every other client asks udp://1.1.1.1 and works on the network '
            'where Nova\'s DoH call to that same address did not. The first '
            'attempt should be the one that answers, not the one that fails');
  });

  test('the form other clients use is understood', () {
    final EchSpec s = EchSpec.parse('cloudflare-ech.com+udp://1.0.0.1');
    expect(s.domain, 'cloudflare-ech.com');
    expect(s.resolver, 'udp://1.0.0.1');
  });

  test('either half alone keeps the other at its default', () {
    expect(EchSpec.parse('udp://9.9.9.9').domain, EchSpec.fallback.domain);
    expect(EchSpec.parse('udp://9.9.9.9').resolver, 'udp://9.9.9.9');
    expect(EchSpec.parse('example.com').resolver, EchSpec.fallback.resolver);
    expect(EchSpec.parse('example.com').domain, 'example.com');
  });

  test('order does not matter, because people paste either way round', () {
    expect(EchSpec.parse('tcp://8.8.8.8+example.com'),
        EchSpec.parse('example.com+tcp://8.8.8.8'));
  });

  test('tcp and DoH resolvers are accepted too', () {
    expect(EchSpec.parse('x.com+tcp://1.1.1.1').resolver, 'tcp://1.1.1.1');
    expect(EchSpec.parse('x.com+https://dns.google/dns-query').resolver,
        'https://dns.google/dns-query');
  });

  test('nonsense costs the typist their customisation, not their connection',
      () {
    expect(EchSpec.parse('   '), EchSpec.fallback);
    expect(EchSpec.parse('what is this'), EchSpec.fallback);
    expect(EchSpec.parse('+++'), EchSpec.fallback);
  });

  test('what is stored round-trips through the editor', () {
    for (final String t in <String>[
      'cloudflare-ech.com+udp://1.0.0.1',
      'example.com+https://dns.google/dns-query',
    ]) {
      expect(EchSpec.parse(EchSpec.parse(t).text), EchSpec.parse(t));
      expect(EchSpec.parse(t).text, t);
    }
  });

  test('a different spec is a different cache entry', () {
    expect(EchSpec.parse('a.com+udp://1.1.1.1').cacheKey,
        isNot(EchSpec.parse('b.com+udp://1.1.1.1').cacheKey));
    expect(EchSpec.parse('a.com+udp://1.1.1.1').cacheKey,
        isNot(EchSpec.parse('a.com+udp://8.8.8.8').cacheKey));
  });
}
