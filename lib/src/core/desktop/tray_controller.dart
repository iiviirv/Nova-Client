import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../logging/nova_log.dart';
import '../proxy/proxy_controller.dart';

/// Windows and macOS: keep Nova in the menu bar / notification area.
///
/// A VPN is something you turn on and forget, so having to leave its window
/// open on the desktop for it to keep working is wrong. Closing the window now
/// hides it and Nova keeps running, with the tunnel untouched; the tray icon is
/// how you get it back, and its menu can connect, disconnect and quit without
/// opening the window at all.
///
/// Quit is the only thing that actually ends the process, and it disconnects
/// first: leaving a core running with no window and no icon would strand the
/// user's traffic in a tunnel nothing on screen admits to.
class TrayController with TrayListener, WindowListener {
  TrayController(this._proxy, {required this.strings});

  /// Whether this platform has a tray at all. Linux desktop environments vary
  /// too much to promise this, so it stays to the two we ship.
  static bool get supported => Platform.isMacOS || Platform.isWindows;

  final ProxyController _proxy;

  /// The menu labels, in the user's language. Re-read on every rebuild so a
  /// language change reaches the menu.
  TrayStrings Function() strings;

  bool _started = false;
  bool _quitting = false;

  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    try {
      await windowManager.ensureInitialized();
      // Closing the window hides it instead of ending the process. Without
      // this, "close" and "quit" are the same thing and the tray is pointless.
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      await _applyIcon();
      await _rebuildMenu();
      _proxy.addListener(_onProxyChanged);
    } catch (e) {
      // A tray is a convenience. If the platform refuses one, the app must
      // still run normally with its window.
      NovaLog.instance.write('Could not set up the tray: $e',
          level: NovaLogLevel.warn);
      _started = false;
    }
  }

  Future<void> dispose() async {
    if (!_started) return;
    _proxy.removeListener(_onProxyChanged);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    _started = false;
  }

  Future<void> _applyIcon() async {
    // macOS wants a template image (alpha only) so the menu bar can tint it for
    // a light or dark bar; Windows wants a real .ico.
    await trayManager.setIcon(
      Platform.isMacOS
          ? 'assets/tray/nova-tray-mac.png'
          : 'assets/tray/nova-tray.ico',
      isTemplate: Platform.isMacOS,
    );
  }

  void _onProxyChanged() {
    // The menu carries the connection state (its title line, and which of
    // connect/disconnect is enabled), so it is rebuilt when that changes.
    unawaited(_rebuildMenu());
  }

  Future<void> _rebuildMenu() async {
    if (!_started) return;
    final TrayStrings s = strings();
    final bool active = _proxy.state.isActive;
    final bool busy = _proxy.state.isBusy;
    final String status = busy
        ? s.connecting
        : active
            ? s.connected
            : s.disconnected;
    try {
      await trayManager.setToolTip('Nova  ${status.toLowerCase()}');
      await trayManager.setContextMenu(Menu(items: <MenuItem>[
        MenuItem(key: 'status', label: status, disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'show', label: s.show),
        MenuItem(key: 'connect', label: s.connect, disabled: active || busy),
        MenuItem(
            key: 'disconnect', label: s.disconnect, disabled: !active && !busy),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: s.quit),
      ]));
    } catch (e) {
      NovaLog.instance
          .write('Could not update the tray menu: $e', level: NovaLogLevel.warn);
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    // Windows: a left click on the icon is "give me the window back". macOS
    // opens the menu on either button, which is that platform's convention.
    if (Platform.isWindows) {
      unawaited(_show());
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_show());
      case 'connect':
        unawaited(_proxy.connect());
      case 'disconnect':
        unawaited(_proxy.disconnect());
      case 'quit':
        unawaited(quit());
    }
  }

  /// The UI language changed: rebuild the menu so it is in it.
  void refreshLabels() => unawaited(_rebuildMenu());

  /// Ends the app for real. Disconnects first and waits for it, so no core is
  /// left running behind a window and an icon that are both gone.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    NovaLog.instance.write('Quitting from the tray');
    try {
      if (_proxy.state.isActive || _proxy.state.isBusy) {
        await _proxy.disconnect().timeout(const Duration(seconds: 8));
      }
    } catch (_) {
      // Quit anyway: a core that will not stop must not trap the user in the
      // app. The desktop controller kills its child process on exit.
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    // The window's red button hides Nova; only the tray's Quit ends it.
    if (_quitting) return;
    unawaited(windowManager.hide());
  }
}

/// The tray menu's labels, passed in so this file stays out of the l10n table's
/// business and can be built before a BuildContext exists.
@immutable
class TrayStrings {
  const TrayStrings({
    required this.show,
    required this.connect,
    required this.disconnect,
    required this.quit,
    required this.connected,
    required this.connecting,
    required this.disconnected,
  });

  final String show;
  final String connect;
  final String disconnect;
  final String quit;
  final String connected;
  final String connecting;
  final String disconnected;
}

/// The tray menu's labels, in the user's language.
///
/// They live here rather than in the l10n table because the tray exists before
/// any BuildContext does, and NovaStrings is looked up from one.
TrayStrings trayStringsFor(bool farsi) => farsi
    ? const TrayStrings(
        show: 'نمایش نوا',
        connect: 'اتصال',
        disconnect: 'قطع اتصال',
        quit: 'خروج از نوا',
        connected: 'متصل',
        connecting: 'در حال اتصال',
        disconnected: 'قطع',
      )
    : const TrayStrings(
        show: 'Show Nova',
        connect: 'Connect',
        disconnect: 'Disconnect',
        quit: 'Quit Nova',
        connected: 'Connected',
        connecting: 'Connecting',
        disconnected: 'Disconnected',
      );
