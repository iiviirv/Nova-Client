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

  group('a network service name cannot become a root command', () {
    // The service names come from `networksetup -listallnetworkservices` and are
    // interpolated into a string run as root through
    // `osascript ... with administrator privileges`. Quoting them in double
    // quotes and escaping only `"` is not enough: the shell expands $(...) and
    // backticks INSIDE double quotes, and a name ending in a backslash closes
    // the AppleScript literal early and turns the rest into AppleScript.
    //
    // Renaming a network service needs admin or an approved VPN configuration,
    // so this is privilege persistence rather than a remote hole. What made it
    // urgent is that the startup sweep now reaches this code with no user
    // action at all.
    test('command substitution in a service name is inert', () {
      final String q = DesktopProxyController.debugShellArg(r'Wi-Fi$(id -un)');
      expect(q.startsWith("'"), isTrue);
      expect(q.endsWith("'"), isTrue);
      // Inside single quotes the shell expands nothing.
      expect(q, equals(r"'Wi-Fi$(id -un)'"));
    });

    test('backticks are inert', () {
      expect(DesktopProxyController.debugShellArg('Wi-Fi`id`'),
          equals("'Wi-Fi`id`'"));
    });

    test('a trailing backslash cannot escape the quoting', () {
      expect(DesktopProxyController.debugShellArg(r'Wi-Fi\\'),
          equals(r"'Wi-Fi\\'"),
          reason: 'a backslash has no special meaning inside single quotes');
    });

    test('an embedded single quote is closed and reopened, not escaped away',
        () {
      // The one character single quoting cannot contain, so it has to be
      // spliced: 'a'\''b' is the shell's way of writing a'b.
      expect(DesktopProxyController.debugShellArg("Vahid's Wi-Fi"),
          equals(r"'Vahid'\''s Wi-Fi'"));
    });

    test('an ordinary name is unchanged apart from the quotes', () {
      expect(DesktopProxyController.debugShellArg('Wi-Fi'), equals("'Wi-Fi'"));
      expect(DesktopProxyController.debugShellArg('Thunderbolt Bridge'),
          equals("'Thunderbolt Bridge'"));
    });
  });

  group('waiting for a core to release its control port', () {
    // Field report from Iran, macOS: switching servers asked for the password
    // and then failed with "Full-device mode failed to start", and the error
    // quoted INFO lines showing the TUN accepting connections and VLESS
    // carrying them. The tunnel was working; only the control API was
    // unreachable, because teardown slept a flat 600ms and hoped the previous
    // root core had exited. It often had not, so the new core could not bind
    // the port, and _waitForCore gave up about twenty seconds later.
    test('a held port is reported as still in use', () async {
      final ServerSocket held =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => held.close());
      held.listen((Socket c) => c.destroy());
      expect(await DesktopProxyController.nothingIsListening(held.port), isFalse,
          reason: 'starting a second core against this port is what produced '
              'the false "failed to start"');
    });

    test('the port reads free as soon as the holder goes away', () async {
      final ServerSocket held =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int port = held.port;
      held.listen((Socket c) => c.destroy());
      expect(await DesktopProxyController.nothingIsListening(port), isFalse);
      await held.close();
      expect(await DesktopProxyController.nothingIsListening(port), isTrue,
          reason: 'this is the transition the teardown now waits for instead '
              'of sleeping a fixed 600ms');
    });
  });

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

  group('the startup sweep only touches a setting Nova owns', () {
    // These assert the RULE, not the plumbing. When the rule was inlined, the
    // tests here reached SharedPreferences, which throws in a plain test
    // context, and the catch swallowed it: three tests passed while asserting
    // nothing about the sweep at all. They would have passed against a sweep
    // that cleared unconditionally.

    test('no ownership marker means it is not ours, so it is left alone', () {
      // The dangerous case: another proxy client configured on the same port
      // and not running right now looks exactly like our own leftovers.
      expect(
          DesktopProxyController.shouldClear(
              ownedPort: null, namesOurPort: true, nothingListening: true),
          isFalse,
          reason: "a port number is not ownership, and clearing someone else's "
              'setting breaks a working setup Nova has nothing to do with');
    });

    test('a marker for a port the OS is not using is left alone', () {
      expect(
          DesktopProxyController.shouldClear(
              ownedPort: 2080, namesOurPort: false, nothingListening: true),
          isFalse);
    });

    test('something still listening means the setting is in use', () {
      expect(
          DesktopProxyController.shouldClear(
              ownedPort: 2080, namesOurPort: true, nothingListening: false),
          isFalse,
          reason: 'a live listener may be another proxy app or a second Nova');
    });

    test('ours, in use by the OS, and dead: clear it', () {
      // The machine-breaking case the sweep exists for: Nova set it, then died
      // without cleaning up, and every app on the computer now has no network.
      expect(
          DesktopProxyController.shouldClear(
              ownedPort: 2080, namesOurPort: true, nothingListening: true),
          isTrue);
    });

    test('does nothing when told not to manage the system proxy', () async {
      final DesktopProxyController c =
          DesktopProxyController(manageSystemProxy: false);
      await c.clearStaleSystemProxy();
      expect(c.systemProxyOn, isFalse);
      c.dispose();
    });
  });
}
