import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import '../../logging/nova_log.dart';
import '../../models/proxy_profile.dart';
import 'aether_core.dart';
import 'aether_env.dart';
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
  /// [throughPort] is the local proxy the live tunnel is serving on, when
  /// there is one. The registration dials out through it instead of straight
  /// at the network, which is the whole point of doing this after a connect.
  static Future<AetherRegistrationSkip?> afterConnect(ProxyProfile? active,
      {bool? iOS, int? throughPort}) async {
    if (!ownsRegistration(iOS: iOS)) return AetherRegistrationSkip.iosExtension;
    if (isAetherLink(active?.uri)) return AetherRegistrationSkip.aetherProfile;
    try {
      final Directory support = await getApplicationSupportDirectory();
      // Say so plainly rather than relying on the operating system to route
      // the core's sockets into the tunnel. Measured against another client on
      // the same connection: it dialled the WARP API through its own proxy and
      // registered in seconds, while Nova, with a tunnel up, went direct and
      // failed every way in 137 seconds.
      if (throughPort != null) {
        AetherEnv.setUpstream('127.0.0.1:$throughPort');
        NovaLog.instance.write(
            'Taking the Cloudflare registration for WARP through the tunnel '
            'that is up, on 127.0.0.1:$throughPort.');
      }
      try {
        await ensure(base: baseIn(support));
      } finally {
        // Process-wide, so it must not outlive this call: a later connection
        // with nothing listening there would dial a port that is gone.
        if (throughPort != null) AetherEnv.setUpstream(null);
      }
    } catch (_) {
      // Nobody asked for this; a failure is not the user's to see.
    }
    return null;
  }

  /// Throw away every saved registration, so the next connection takes a new
  /// one.
  ///
  /// Field report, 2026-10-10: a registration was taken through a tunnel that
  /// was up but carrying nothing, the log said it was saved, and from then on
  /// WARP could never connect. [have] saw a file and skipped the call on every
  /// later attempt, including after connecting to a server that worked, so the
  /// only way out was to reinstall the app. His words: "even when I connected
  /// to a healthy server afterwards it never tried to get the key again, even
  /// though the key was broken".
  ///
  /// A saved registration has to be disposable for that reason. One that does
  /// not work is worse than none at all: none at least gets replaced.
  ///
  /// Returns how many files were removed, so a caller can say whether there
  /// was anything to remove.
  static int forget(String base) {
    int gone = 0;
    final File exact = File(base);
    try {
      if (exact.existsSync()) {
        exact.deleteSync();
        gone++;
      }
    } catch (_) {
      // A file that cannot be deleted is not worth failing a connection over.
    }
    final Directory dir = exact.parent;
    if (!dir.existsSync()) return gone;
    final String prefix = base.split(Platform.pathSeparator).last;
    for (final FileSystemEntity e in dir.listSync()) {
      final String name = e.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('$prefix-')) continue;
      try {
        if (e is File) {
          e.deleteSync();
          gone++;
        }
      } catch (_) {}
    }
    return gone;
  }

  /// Drop the saved registration and take a fresh one, through [throughPort]
  /// when a tunnel is up.
  ///
  /// This is the way out of a registration that was saved but does not work.
  /// Without it the only remedy was reinstalling the app.
  static Future<bool> renew({int? throughPort}) async {
    if (!ownsRegistration()) return false;
    try {
      final Directory support = await getApplicationSupportDirectory();
      final String base = baseIn(support);
      final int gone = forget(base);
      NovaLog.instance.write(gone == 0
          ? 'No saved WARP registration to replace; taking a new one.'
          : 'Threw away the saved WARP registration ($gone file'
              '${gone == 1 ? '' : 's'}); taking a new one.');
      if (throughPort != null) {
        AetherEnv.setUpstream('127.0.0.1:$throughPort');
      }
      try {
        return await ensure(base: base);
      } finally {
        if (throughPort != null) AetherEnv.setUpstream(null);
      }
    } catch (e) {
      NovaLog.instance.write('Could not renew the WARP registration: $e',
          level: NovaLogLevel.warn);
      return false;
    }
  }

  /// True when at least one registration already exists, so there is nothing
  /// to do and no reason to spend a call.
  static bool have(String base) {
    // The two transports do not agree on where to put this, which is measured
    // rather than assumed: WireGuard writes the identity to `base` exactly,
    // with no suffix, while MASQUE writes it to `base-masque`.
    //
    // Only the suffixed form was checked here, so a WireGuard registration was
    // invisible. On a device where the MASQUE half fails and the WireGuard half
    // succeeds, that reads as "no registration" forever and Nova registers
    // again on every single connect, which is exactly what a tester reported
    // seeing in his log. The registration was there the whole time; this could
    // not see it.
    final File exact = File(base);
    if (exact.existsSync() && exact.lengthSync() > 0) return true;

    final Directory dir = exact.parent;
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

    // The filename is in the line because a tester reported seeing the "saved"
    // message on every connect, which should be impossible: this returns above
    // when a registration already exists. The cause turned out to be that
    // WireGuard writes to `base` exactly while this only looked for `base-*`,
    // so the name is the diagnostic that matters.
    //
    // The name, not the path. This log is made to be pasted into a support
    // chat, and the full path carries the OS account name, which on a desktop
    // is usually the person's real one. NovaLog.redact now strips home
    // directories as well, so this is belt and braces.
    NovaLog.instance.write(
        'No Cloudflare registration for WARP yet (looked for '
        '${base.split(Platform.pathSeparator).last} in the app folder). '
        'Taking one through the tunnel that is up, so WARP can work later on '
        'networks that block it.');

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
          NovaLog.instance.write(
              'WARP registration for ${mode.name}'
              '${options.ech ? ' behind ECH' : ''} did not take.',
              level: NovaLogLevel.warn);
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
