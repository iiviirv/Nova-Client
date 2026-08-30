import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../logging/nova_log.dart';

/// The macOS Network Extension: Nova's tunnel, run by macOS instead of by an
/// administrator prompt.
///
/// Creating a tunnel device needs root. Nova used to get there by asking for
/// administrator rights on every single connect, through an AppleScript prompt,
/// which is the "you move a finger in the app and it asks for a password"
/// report. A system extension is approved once by the user, in System Settings,
/// and after that macOS starts it with the privileges it needs. It also gives
/// Nova an entry in the Network pane beside Wi-Fi, the way every other VPN on
/// the Mac appears.
///
/// The extension runs exactly the config the bundled core ran, Clash API and
/// all, so everything else in the desktop controller (traffic, latency, health,
/// the server board) works against it unchanged. This class is only the four
/// questions that have to cross the process boundary.
class MacTunnelExtension {
  MacTunnelExtension._();

  static const MethodChannel _channel = MethodChannel('nova.tun/control');

  /// Whether this build can use the extension at all.
  ///
  /// False on any build that was not signed with the entitlement, which
  /// includes every local debug build, and false on every platform but macOS.
  /// The caller falls back to the elevated core, so a developer build still
  /// connects, with the prompt.
  static Future<bool> get available async {
    if (!Platform.isMacOS) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Asks macOS to install the extension. Returns true once it is active.
  ///
  /// The first call on a machine answers [needsApproval]: macOS shows the user
  /// a prompt in System Settings and installs nothing until they allow it.
  /// That is the one interaction this whole feature costs, and it happens once.
  static Future<MacExtensionState> activate() async {
    try {
      final String? r = await _channel.invokeMethod<String>('activate');
      switch (r) {
        case 'completed':
          return MacExtensionState.active;
        case 'needsApproval':
          return MacExtensionState.needsApproval;
        default:
          return MacExtensionState.failed;
      }
    } catch (e) {
      NovaLog.instance.write('Tunnel extension could not be activated: $e',
          level: NovaLogLevel.warn);
      return MacExtensionState.failed;
    }
  }

  /// Starts the tunnel with [configJson] (and [xrayConfigJson] for an xhttp
  /// node). Throws with the reason if macOS refuses.
  static Future<void> start(String configJson, {String? xrayConfigJson}) async {
    await _channel.invokeMethod<bool>('start', <String, dynamic>{
      'configJson': configJson,
      if (xrayConfigJson != null) 'xrayConfigJson': xrayConfigJson,
    });
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (e) {
      NovaLog.instance
          .write('Tunnel extension stop: $e', level: NovaLogLevel.warn);
    }
  }

  /// What macOS says the tunnel is doing: connected, connecting, disconnecting,
  /// disconnected, or invalid when no configuration exists yet.
  static Future<String> status() async {
    try {
      return await _channel.invokeMethod<String>('status') ?? 'invalid';
    } catch (_) {
      return 'invalid';
    }
  }
}

enum MacExtensionState {
  /// Installed and ready.
  active,

  /// macOS is waiting for the user to allow it in System Settings.
  needsApproval,

  /// It could not be installed, so the caller falls back to the elevated core.
  failed,
}
