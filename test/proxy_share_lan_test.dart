import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Sharing the local proxy on the network is useful and dangerous in the same
/// breath: a TV or a console that cannot run Nova can be pointed at a phone
/// that can, and so can everyone else on a hotel wifi. These tests are about
/// the second half.
Map<String, dynamic> inboundOf(SingboxRouteOptions o) {
  final List<dynamic> inbounds =
      SingboxConfig.inboundsForTest(o) as List<dynamic>;
  return (inbounds.firstWhere((dynamic i) =>
      (i as Map<String, dynamic>)['tag'] == 'proxy-in') as Map<String, dynamic>);
}

void main() {
  test('the proxy stays on loopback unless asked otherwise', () {
    const SingboxRouteOptions o = SingboxRouteOptions(mixedInboundPort: 2080);
    expect(inboundOf(o)['listen'], '127.0.0.1');
  });

  // The whole point of the feature, and the only way it should ever happen.
  test('sharing on the network binds every interface', () {
    const SingboxRouteOptions o =
        SingboxRouteOptions(mixedInboundPort: 2080, mixedInboundOnLan: true);
    expect(inboundOf(o)['listen'], '0.0.0.0');
    expect(inboundOf(o)['listen_port'], 2080);
  });

  test('no credentials means no users block at all', () {
    const SingboxRouteOptions o =
        SingboxRouteOptions(mixedInboundPort: 2080, mixedInboundOnLan: true);
    expect(inboundOf(o).containsKey('users'), isFalse);
  });

  test('credentials reach the core in the shape it expects', () {
    const SingboxRouteOptions o = SingboxRouteOptions(
      mixedInboundPort: 2080,
      mixedInboundOnLan: true,
      mixedInboundUsers: <({String user, String pass})>[
        (user: 'nova', pass: 's3cret'),
      ],
    );
    final List<dynamic> users = inboundOf(o)['users'] as List<dynamic>;
    expect(users, hasLength(1));
    expect((users.first as Map<String, dynamic>)['username'], 'nova');
    expect((users.first as Map<String, dynamic>)['password'], 's3cret');
  });

  // A wide bind with no TUN is the case a user reaches by turning the feature
  // on; it must not quietly also change what else the core listens on.
  test('sharing does not add or remove any other inbound', () {
    const SingboxRouteOptions off =
        SingboxRouteOptions(mixedInboundPort: 2080);
    const SingboxRouteOptions on =
        SingboxRouteOptions(mixedInboundPort: 2080, mixedInboundOnLan: true);
    final List<dynamic> a = SingboxConfig.inboundsForTest(off) as List<dynamic>;
    final List<dynamic> b = SingboxConfig.inboundsForTest(on) as List<dynamic>;
    expect(b.length, a.length);
    expect(
        b.map((dynamic i) => (i as Map<String, dynamic>)['tag']).toList(),
        a.map((dynamic i) => (i as Map<String, dynamic>)['tag']).toList());
  });

  test('copyWith carries the sharing settings', () {
    const SingboxRouteOptions o = SingboxRouteOptions(mixedInboundPort: 2080);
    final SingboxRouteOptions shared = o.copyWith(mixedInboundOnLan: true);
    expect(shared.mixedInboundOnLan, isTrue);
    // And the default is not lost by a copy that says nothing about it.
    expect(shared.copyWith(mixedInboundPort: 3080).mixedInboundOnLan, isTrue);
  });
}
