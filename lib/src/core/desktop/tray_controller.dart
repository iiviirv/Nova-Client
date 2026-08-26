import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      await _restoreBounds();
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
    _boundsSave?.cancel();
    await trayManager.destroy();
    _started = false;
  }

  /// What the menu last displayed, so an unchanged rebuild is skipped.
  String? _menuSig;

  Timer? _boundsSave;

  static const String _boundsKey = 'window_bounds';

  /// Put the window back where the user left it.
  ///
  /// Every launch used to open at the default size in the default place, so
  /// anyone who had sized Nova to a corner of their screen had to do it again
  /// after each quit.
  Future<void> _restoreBounds() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String>? v = prefs.getStringList(_boundsKey);
      if (v == null || v.length != 4) return;
      final List<double?> n = v.map(double.tryParse).toList();
      if (n.any((double? d) => d == null || !d.isFinite)) return;
      final double w = n[2]!, h = n[3]!;
      // A saved size below the minimum, or a window parked off a screen that is
      // no longer attached, would restore to somewhere the user cannot reach it.
      if (w < 320 || h < 400) return;
      final Rect saved = Rect.fromLTWH(n[0]!, n[1]!, w, h);
      final Display d = await screenRetriever.getPrimaryDisplay();
      final Size screen = d.size;
      if (saved.left < -saved.width + 80 ||
          saved.top < -40 ||
          saved.left > screen.width - 80 ||
          saved.top > screen.height - 40) {
        // Off-screen: keep the size the user chose, drop the position.
        await windowManager.setSize(saved.size);
        return;
      }
      await windowManager.setBounds(saved);
    } catch (e) {
      NovaLog.instance.write('Could not restore the window position: $e',
          level: NovaLogLevel.warn);
    }
  }

  /// Remember the geometry, a moment after the user stops dragging. Resizing
  /// fires continuously, so writing on every frame would hammer the disk for a
  /// value only the last one of which matters.
  void _rememberBounds() {
    _boundsSave?.cancel();
    _boundsSave = Timer(const Duration(milliseconds: 500), () async {
      try {
        final Rect b = await windowManager.getBounds();
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_boundsKey, <String>[
          '${b.left}',
          '${b.top}',
          '${b.width}',
          '${b.height}',
        ]);
      } catch (_) {}
    });
  }

  @override
  void onWindowResized() => _rememberBounds();

  @override
  void onWindowMoved() => _rememberBounds();

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

  Future<void> _rebuildMenu({bool force = false}) async {
    if (!_started) return;
    final TrayStrings s = strings();
    final bool active = _proxy.state.isActive;
    final bool busy = _proxy.state.isBusy;
    final String status = busy
        ? s.connecting
        : active
            ? s.connected
            : s.disconnected;
    // Only touch the tray when what it displays actually changed. The proxy
    // notifies on every traffic-stats tick, once a second while connected, and
    // rebuilding on each one meant Windows replaced the menu underneath itself:
    // an open menu visibly re-rendered every second and would not dismiss when
    // it lost focus. None of those ticks change a label here.
    final String sig = '$status|$active|$busy|${s.show}|${s.quit}';
    if (!force && sig == _menuSig) return;
    _menuSig = sig;
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
      unawaited(_popUpMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_popUpMenu());
  }

  /// Show the tray menu.
  ///
  /// On Windows the menu would not go away when you clicked somewhere else: it
  /// stayed up until you picked something from it. That is the documented
  /// consequence of calling TrackPopupMenu for a notification-area icon without
  /// making the owner window the foreground window first, and the plugin only
  /// does that when it is asked to. Windows is the only platform that needs it;
  /// asking for it on macOS would drag the window forward on every menu-bar
  /// click, which is not what a menu-bar app should do.
  Future<void> _popUpMenu() =>
      trayManager.popUpContextMenu(bringAppToFront: Platform.isWindows);

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
  void refreshLabels() => unawaited(_rebuildMenu(force: true));

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
