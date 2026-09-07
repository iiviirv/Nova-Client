import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/desktop_proxy_controller.dart';

/// Leaving the machine pointing at a proxy that is not there.
///
/// Seen on a real Mac: proxy mode set the system proxy on every network
/// service, the disconnect then failed, and the setting stayed. Nothing was
/// listening on the port any more, so every app that follows the system proxy
/// lost the network, with nothing on screen connecting that to Nova. The user
/// had to be told which `networksetup` commands to run.
///
/// Three holes made that possible, and the dangerous one is the last: no
/// in-process teardown can run at all when the app is killed or crashes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what counts as a stale setting', () {
    test('a port with a listener is in use, so the setting is not stale',
        () async {
      final ServerSocket live =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => live.close());
      live.listen((Socket s) => s.destroy());
      expect(await DesktopProxyController.nothingIsListening(live.port), isFalse,
          reason: 'another proxy app on this port must not have the user\'s '
              'setting cleared out from under it');
    });

    test('a port nothing answers on is stale', () async {
      final ServerSocket s =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = s.port;
      await s.close();
      expect(await DesktopProxyController.nothingIsListening(deadPort), isTrue,
          reason: 'this is the machine-breaking case the sweep exists for');
    });
  });

  group('the startup sweep is narrow enough to be safe', () {
    test('does nothing when told not to manage the system proxy', () async {
      final DesktopProxyController c =
          DesktopProxyController(manageSystemProxy: false);
      // Must return without touching anything, whatever the machine looks like.
      await c.clearStaleSystemProxy();
      expect(c.systemProxyOn, isFalse);
      c.dispose();
    });

    test('leaves a port alone while something is still serving it', () async {
      // The case that must never be "cleaned up": another proxy app, or a
      // second Nova, listening on the same port. Clearing then would break a
      // working setup that has nothing to do with us.
      final ServerSocket live =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => live.close());
      live.listen((Socket s) => s.destroy());

      final DesktopProxyController c =
          DesktopProxyController(socksPort: live.port);
      await c.clearStaleSystemProxy();
      expect(c.systemProxyOn, isFalse,
          reason: 'a live listener means the setting is in use, not stale');
      c.dispose();
    });

    test('a closed port does not by itself cause a change', () async {
      // Reaching "nothing is listening" is necessary but not sufficient: the
      // OS proxy must also actually name our port. On a machine with no Nova
      // proxy set, this must be a no-op even though the port is dead.
      final ServerSocket s =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = s.port;
      await s.close();

      final DesktopProxyController c =
          DesktopProxyController(socksPort: deadPort);
      await c.clearStaleSystemProxy();
      expect(c.systemProxyOn, isFalse);
      c.dispose();
    });
  });
}
