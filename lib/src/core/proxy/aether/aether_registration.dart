import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import '../../logging/nova_log.dart';
import '../../models/proxy_profile.dart';
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
/// Why a connect did not lead to a registration attempt.
///
/// Returned rather than kept private so a test can observe the decision. The
/// first version of this only checked that no file appeared, which passed
/// whether or not the iOS guard was there, because the path lookup throws in a
/// test process and the throw is swallowed by design.
enum AetherRegistrationSkip {
  /// iOS, where the extension owns the registration path.
  iosExtension,

  /// An Aether profile, which registers as part of connecting.
  aetherProfile,
}

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

  /// Whether a registration taken in this process is one the tunnel will read.
  ///
  /// False on iOS, and this is not a limitation to route around here. There
  /// the tunnel belongs to the Network Extension, and the extension builds the
  /// identity path from its own container because only it knows that path (see
  /// `_buildAetherConfig`). A registration taken in the app process would be
  /// written into the app's container, where nothing ever looks: the call
  /// spent, a file saved, and WARP still asking for a registration on the next
  /// connect. Doing this on iOS means asking the extension to take one, which
  /// is work on that side of the boundary.
  ///
  /// [iOS] exists so this decision can be tested off an iPhone.
  static bool ownsRegistration({bool? iOS}) => !(iOS ?? Platform.isIOS);

  /// Whether a profile is an Aether one, which is skipped: those register as
  /// part of connecting, and one that just connected is plainly not blocked.
  static bool isAetherLink(String? uri) =>
      (uri ?? '').trim().toLowerCase().startsWith('aether://');

  /// The single entry point both controllers call when a tunnel comes up.
  ///
  /// Lives here rather than in each controller so the rules about what to skip
  /// are written once and tested once, instead of drifting apart between the
  /// mobile and desktop copies the way `_stopPsiphon` did.
  /// Returns the reason it did nothing, or null when it made an attempt.
  static Future<AetherRegistrationSkip?> afterConnect(ProxyProfile? active,
      {bool? iOS}) async {
    if (!ownsRegistration(iOS: iOS)) return AetherRegistrationSkip.iosExtension;
    if (isAetherLink(active?.uri)) return AetherRegistrationSkip.aetherProfile;
    try {
      final Directory support = await getApplicationSupportDirectory();
      await ensure(base: baseIn(support));
    } catch (_) {
      // Nobody asked for this; a failure is not the user's to see.
    }
    return null;
  }

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
      for (final AetherOptions options in _attemptsFor(mode)) {
        try {
          final bool ok = await _open(core, options, base)
              .timeout(budget, onTimeout: () => false);
          if (ok) {
            NovaLog.instance.write('WARP registration saved for ${mode.name}'
                '${options.ech ? ' behind ECH' : ''}.');
            break;
          }
        } catch (_) {
          // The next attempt may still work, and none of this was asked for.
        }
      }
    }
    return have(base);
  }

  /// What to try for one transport, best first.
  ///
  /// ECH first for MASQUE, then the same call without it. Asking for ECH is not
  /// free to get wrong: when the core cannot fetch a key it fails the job with
  /// NO_ECH_KEY rather than carrying on unencrypted, so a network that blocks
  /// the key lookup would be worse off than before. Hence the plain retry.
  ///
  /// WireGuard is never asked. The core fetches no ECH key for that transport
  /// at all, so the request could only fail. That costs nothing here: the
  /// networks ECH is for block UDP to Cloudflare, which rules WireGuard out
  /// anyway.
  static List<AetherOptions> _attemptsFor(AetherMode mode) => mode ==
          AetherMode.wg
      ? <AetherOptions>[AetherOptions(mode: mode)]
      : <AetherOptions>[
          // HTTP/2 for the ECH attempt, not the h3 default. h3 is QUIC over
          // UDP, and UDP to Cloudflare is blocked on the firewall this is for,
          // so the one attempt most likely to be needed would be the one least
          // likely to complete. Both were measured working off that network, so
          // nothing is lost by preferring the one that also works on it.
          AetherOptions(
              mode: mode, transport: AetherTransport.h2, ech: true),
          AetherOptions(mode: mode),
        ];

  /// Exposed so the fallback order can be asserted: it is the part that keeps a
  /// failed ECH attempt from leaving WARP unregistered.
  @visibleForTesting
  static List<AetherOptions> attemptsForTest(AetherMode mode) =>
      _attemptsFor(mode);

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
