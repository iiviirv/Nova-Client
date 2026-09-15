import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Aether core is started after the tunnel device, never before.
///
/// This ordering is the whole fix for a config that verified and then carried
/// nothing. The core dials its gateway on a socket sing-box does not know
/// about. Opened first, that socket is bound to the phone's real interface;
/// the tunnel device then takes the default route and the gateway's replies
/// are delivered to an address that no longer receives. The core waits out its
/// handshake and shuts down, taking the SOCKS port with it, and every request
/// afterwards fails at the bridge.
///
/// Nothing about that is visible in a type or a signature, so it is asserted
/// here. Reading source is crude; it is also the only thing that fails when
/// someone moves the call back up for a tidier-looking connect path.
void main() {
  final File f = File('lib/src/core/proxy/singbox_proxy_controller.dart');
  final String src = f.readAsStringSync();

  test('the core starts after the platform brings the tunnel up', () {
    final int platformStart = src.indexOf("invokeMethod<void>('start'");
    final int aetherStart = src.indexOf('_startPendingAether()');
    expect(platformStart, isNot(-1), reason: 'the platform start call moved');
    expect(aetherStart, isNot(-1), reason: 'the deferred Aether start is gone');
    expect(aetherStart, greaterThan(platformStart),
        reason: 'starting the core before the tunnel device gives it a socket '
            'bound to the wrong interface, and it dies about ten seconds in');
  });

  test('building the config reserves a port rather than starting a tunnel', () {
    // The config names a port, so one must be picked early. Picking it is fine;
    // dialling the gateway is what has to wait.
    final int build = src.indexOf('Future<String> _buildAetherConfig');
    final int nextMethod = src.indexOf('_PendingAether? _pendingAether', build);
    expect(build, isNot(-1));
    expect(nextMethod, greaterThan(build));
    final String body = src.substring(build, nextMethod);
    expect(body.contains('freeLoopbackPort'), isTrue);
    expect(body.contains('AetherTunnel.start'), isFalse,
        reason: 'the config builder runs before sing-box, so it must not dial');
  });

  test('a failed start leaves no half-open tunnel behind', () {
    // Both have to happen on the failure path, but not necessarily adjacent:
    // this asserted one exact two-line string and broke the moment a third
    // statement was added between them, which is a test failing on formatting
    // rather than on behaviour.
    // Anchored on this path's own comment: the file has three catch blocks and
    // indexOf found the first, which is a different one.
    final int fail = src.indexOf('A half-started Aether tunnel is worse');
    expect(fail, isNot(-1), reason: 'the connect failure path moved');
    final String body = src.substring(fail, fail + 400);
    expect(body.contains('_pendingAether = null;'), isTrue,
        reason: 'a pending start left behind would fire on the next connect');
    expect(body.contains('AetherTunnel.stop()'), isTrue,
        reason: 'sing-box would otherwise forward into a port that never '
            'answers');
  });
}
