import 'dart:async';
import 'dart:io';

import '../../logging/nova_log.dart';
import 'aether_core.dart';
import 'aether_options.dart';
import 'aether_protocol.dart';

/// Gets the WARP registration while some other tunnel is carrying traffic.
///
/// WARP cannot connect until Cloudflare has registered the device, and that
/// registration is a single call made once and reused everywhere afterwards.
/// Some networks block it. A tester in Iran found his Wi-Fi did: WireGuard and
/// Gool could never start there, and the moment he registered once on mobile
/// data the same Wi-Fi worked and kept working.
///
/// His suggestion, and it is the right one: Nova is often already connected
/// through something that does work, a free server or the user's own. While
/// that tunnel is up the registration call goes through it and succeeds. So
/// take it then, quietly, and the blocked network never has to be solved.
///
/// This makes the failure self-healing rather than something the user has to
/// be told about and act on.
abstract final class AetherRegistration {
  /// The path prefix the core is given. It appends the transport, so this
  /// becomes `aether-wg` and `aether-masque` beside it.
  static String baseIn(Directory support) => '${support.path}/aether';

  /// The transports worth registering. Gool is built on WireGuard and shares
  /// its registration, so two calls cover all three protocols Nova offers.
  static const List<AetherMode> _transports = <AetherMode>[
    AetherMode.wg,
    AetherMode.masque,
  ];

  /// True when at least one registration already exists, so there is nothing
  /// to do and no reason to spend a call.
  static bool have(String base) {
    final Directory dir = File(base).parent;
    if (!dir.existsSync()) return false;
    final String prefix = base.split(Platform.pathSeparator).last;
    for (final FileSystemEntity e in dir.listSync()) {
      final String name = e.path.split(Platform.pathSeparator).last;
      // `aether-wg-lastconn` is a connection record, not a registration.
      if (name.startsWith('$prefix-') && !name.endsWith('-lastconn')) {
        if (e is File && e.lengthSync() > 0) return true;
      }
    }
    return false;
  }

  /// Registers, if there is no registration yet. Returns true when one exists
  /// afterwards, either because it already did or because this call made it.
  ///
  /// Deliberately quiet on failure. This runs while the user is connected to
  /// something else and did not ask for it, so a failure is not their problem
  /// to see: WARP will simply ask again the next time it is used.
  static Future<bool> ensure({
    required String base,
    Duration budget = const Duration(seconds: 45),
  }) async {
    if (have(base)) return true;
    if (!AetherCore.available) return false;

    NovaLog.instance.write(
        'No Cloudflare registration for WARP yet. Taking one through the '
        'tunnel that is up, so WARP can work later on networks that block it.');

    final AetherCore core = AetherCore.open();
    for (final AetherMode mode in _transports) {
      try {
        final bool ok = await _open(core, AetherOptions(mode: mode), base)
            .timeout(budget, onTimeout: () => false);
        if (ok) {
          NovaLog.instance.write('WARP registration saved for ${mode.name}.');
        }
      } catch (_) {
        // The next transport may still work, and none of this was asked for.
      }
    }
    return have(base);
  }

  static Future<bool> _open(
      AetherCore core, AetherOptions options, String base) async {
    final AetherReply started = core.identityOpen(options, base: base);
    if (!started.ok) return false;
    final Object? job = started['job'];
    if (job is! num) return false;
    final int id = job.toInt();
    while (true) {
      final AetherJobStatus s = core.jobPoll(id);
      if (!s.isRunning) return s.state == AetherJobState.done;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
