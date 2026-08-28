import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/awg_config.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_outbound_import.dart';

/// An AmneziaWG server from a subscription must keep its version 3 settings.
///
/// A subscription delivers an endpoint as JSON, which Nova turns into a
/// WireGuard `.conf` and parses back. That conversion listed only the 2.0
/// parameters, so every 3.x one was dropped in between: the same server
/// imported from a `.conf` file worked, and from a subscription it did not.
///
/// The failure was quiet and looked like something else entirely. Without the
/// header key the client sends unprotected headers to a server expecting
/// protected ones, so the tunnel comes up, carries nothing, and every lookup
/// through it times out. Reported as "AmneziaWG 3 will not connect", and the
/// logs showed DNS timeouts rather than anything about a missing key.
void main() {
  Map<String, dynamic> endpoint() => <String, dynamic>{
        'type': 'awg',
        'tag': 'AmneziaWG (Germany)',
        'private_key': 'IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=',
        'address': <String>['10.13.13.2/32'],
        'mtu': 1280,
        'jc': 3, 'jmin': 20, 'jmax': 50,
        's1': 15, 's2': 64, 's3': 25, 's4': 12,
        'h1': '977700370', 'h2': '533569368',
        'h3': '1043130680', 'h4': '1223320787',
        'header_protection_key': 'IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=',
        'content_padding_addition': '16-64',
        'rekey_after_time': '100-140',
        'rekey_timeout': '5-8',
        'reject_after_time': '160-200',
        'keepalive_timeout': '8-12',
        'max_handshake_attempts': '10-20',
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{
            'public_key': 'IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=',
            'address': '203.0.113.10',
            'port': 45874,
            'allowed_ips': <String>['0.0.0.0/0', '::/0'],
            'persistent_keepalive_interval': 25,
          }
        ],
      };

  String body(Map<String, dynamic> ep) =>
      '{"outbounds":[],"endpoints":[${_json(ep)}]}';

  test('every version 3 parameter survives the subscription round trip', () {
    final List<ProxyNode> nodes = parseSingboxOutbounds(body(endpoint()));
    expect(nodes, hasLength(1));
    final Map<String, dynamic> out =
        AwgConfig.parseConf(nodes.single.awgConf!).toEndpoint('proxy');

    expect(out['header_protection_key'],
        'IMLJ1cUmM0jZlNSRXPZ4mHtQBLZ1sBGCUlmM8xVUZ1Y=',
        reason: 'losing this is a tunnel that connects and carries nothing');
    expect(out['content_padding_addition'], '16-64');
    expect(out['rekey_after_time'], '100-140');
    expect(out['rekey_timeout'], '5-8');
    expect(out['reject_after_time'], '160-200');
    expect(out['keepalive_timeout'], '8-12');
    expect(out['max_handshake_attempts'], '10-20');
  });

  test('the 2.0 parameters still come through unchanged', () {
    final List<ProxyNode> nodes = parseSingboxOutbounds(body(endpoint()));
    final Map<String, dynamic> out =
        AwgConfig.parseConf(nodes.single.awgConf!).toEndpoint('proxy');
    expect(out['jc'], 3);
    expect(out['s1'], 15);
    expect(out['s4'], 12);
    expect(out['h1'], '977700370');
    expect(out['mtu'], 1280);
  });

  test('a 2.0 server gains nothing it did not send', () {
    final Map<String, dynamic> ep = endpoint();
    for (final String k in const <String>[
      'header_protection_key', 'content_padding_addition', 'rekey_after_time',
      'rekey_timeout', 'reject_after_time', 'keepalive_timeout',
      'max_handshake_attempts',
    ]) {
      ep.remove(k);
    }
    final List<ProxyNode> nodes = parseSingboxOutbounds(body(ep));
    final Map<String, dynamic> out =
        AwgConfig.parseConf(nodes.single.awgConf!).toEndpoint('proxy');
    expect(out.containsKey('header_protection_key'), isFalse);
    expect(out.containsKey('rekey_timeout'), isFalse);
    expect(out['jc'], 3);
  });
}

String _json(Object? o) {
  if (o is String) return '"$o"';
  if (o is Map) {
    return '{${o.entries.map((MapEntry<Object?, Object?> e) => '"${e.key}":${_json(e.value)}').join(',')}}';
  }
  if (o is List) return '[${o.map(_json).join(',')}]';
  return '$o';
}
