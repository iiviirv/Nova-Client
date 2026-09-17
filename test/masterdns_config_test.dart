import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/masterdns/masterdns_config.dart';

/// The config other clients share uses lower-case names the engine ignores, and
/// carries resolvers in a field the engine cannot read. Passing it through
/// unchanged starts a tunnel with no domain, no key and no resolvers.
void main() {
  // Shaped like the config in the tester's screenshots.
  const String friendly = '''
{
  "domain" : "a.example.sbs",
  "key" : "8ab8b1150c0ffee0123456789abcdef0",
  "LISTEN_IP" : "127.0.0.1",
  "LISTEN_PORT" : 60948,
  "method" : 1,
  "PROTOCOL_TYPE" : "SOCKS5",
  "resolvers" : ["8.8.8.8", "1.1.1.1", "208.67.222.222"]
}''';

  test('the shared config is read with its lower-case names', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText(friendly)!;
    expect(c.domains, <String>['a.example.sbs']);
    expect(c.key, '8ab8b1150c0ffee0123456789abcdef0');
    expect(c.method, MasterDnsMethod.xor);
    expect(c.resolvers, <String>['8.8.8.8', '1.1.1.1', '208.67.222.222']);
  });

  // The whole reason for a translation step.
  test('the engine is given the upper-case names it actually reads', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText(friendly)!;
    final Map<String, dynamic> e =
        jsonDecode(c.engineJson(port: 18000)) as Map<String, dynamic>;
    expect(e['DOMAINS'], <String>['a.example.sbs']);
    expect(e['ENCRYPTION_KEY'], '8ab8b1150c0ffee0123456789abcdef0');
    expect(e['DATA_ENCRYPTION_METHOD'], 1);
    expect(e.containsKey('domain'), isFalse);
    expect(e.containsKey('key'), isFalse);
  });

  test('resolvers go to the file, never into the engine JSON', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText(friendly)!;
    final Map<String, dynamic> e =
        jsonDecode(c.engineJson(port: 18000)) as Map<String, dynamic>;
    expect(e.keys.where((String k) => k.toLowerCase().contains('resolver')),
        isEmpty);
    expect(c.resolversFile, '8.8.8.8\n1.1.1.1\n208.67.222.222\n');
  });

  test('the listen address is always loopback, whatever was pasted', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText(friendly
        .replaceAll('"127.0.0.1"', '"0.0.0.0"'))!;
    final Map<String, dynamic> e =
        jsonDecode(c.engineJson(port: 18000)) as Map<String, dynamic>;
    expect(e['LISTEN_IP'], '127.0.0.1');
    expect(e['LISTEN_PORT'], 18000, reason: 'the port is Nova\'s to choose');
  });

  test('the engine\'s own upper-case JSON is read too', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText(
        '{"DOMAINS":["v.example.com"],"ENCRYPTION_KEY":"k","DATA_ENCRYPTION_METHOD":5}')!;
    expect(c.domains, <String>['v.example.com']);
    expect(c.method, MasterDnsMethod.aes256);
  });

  test('the engine\'s TOML sample is read', () {
    final MasterDnsConfig c = MasterDnsConfig.parseText('''
# comment
DOMAINS = ["v.example.com", "w.example.com"]
DATA_ENCRYPTION_METHOD = 2
ENCRYPTION_KEY = "abc123"
PROTOCOL_TYPE = "SOCKS5"
''')!;
    expect(c.domains, <String>['v.example.com', 'w.example.com']);
    expect(c.key, 'abc123');
    expect(c.method, MasterDnsMethod.chacha20);
  });

  test('a method given by name is understood', () {
    expect(MasterDnsMethod.parse('XOR'), MasterDnsMethod.xor);
    expect(MasterDnsMethod.parse('aes-256-gcm'), MasterDnsMethod.aes256);
    expect(MasterDnsMethod.parse(3), MasterDnsMethod.aes128);
    expect(MasterDnsMethod.parse('3'), MasterDnsMethod.aes128);
  });

  test('a link round-trips, name included', () {
    final MasterDnsConfig c = MasterDnsConfig(
      domains: const <String>['a.example.sbs'],
      key: 'secret-key',
      method: MasterDnsMethod.chacha20,
      resolvers: const <String>['8.8.8.8', '1.1.1.1'],
      name: 'Home DNS',
    );
    final MasterDnsConfig back = MasterDnsConfig.parseLink(c.toLink())!;
    expect(back.domains, c.domains);
    expect(back.key, c.key);
    expect(back.method, c.method);
    expect(back.resolvers, c.resolvers);
    expect(back.name, 'Home DNS');
  });

  test('what is missing is named', () {
    expect(const MasterDnsConfig(domains: <String>[], key: 'k').problem,
        'no domain');
    expect(
        const MasterDnsConfig(
                domains: <String>['d'], key: '', resolvers: <String>['1.1.1.1'])
            .problem,
        'no encryption key');
    expect(
        const MasterDnsConfig(domains: <String>['d'], key: 'k').problem,
        'no resolvers');
    expect(
        const MasterDnsConfig(
            domains: <String>['d'],
            key: '',
            method: MasterDnsMethod.none,
            resolvers: <String>['1.1.1.1']).problem,
        isNull,
        reason: 'no encryption needs no key');
  });

  test('something that is not a MasterDNS config is refused', () {
    expect(MasterDnsConfig.parseText('vless://abc@host:443'), isNull);
    expect(MasterDnsConfig.parseText('{"outbounds":[]}'), isNull);
    expect(MasterDnsConfig.parseLink('vless://x'), isNull);
  });
}
