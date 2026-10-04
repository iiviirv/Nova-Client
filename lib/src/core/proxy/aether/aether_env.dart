import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../logging/nova_log.dart';

typedef _SetenvC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _Setenv = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _PutenvC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Putenv = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// Settings the Aether core reads from the environment rather than from a job.
///
/// The core looks its ECH key up over DNS and defaults to `udp://1.1.1.1`
/// (`aether/src/dns.rs`). That default is useless exactly where ECH is needed:
/// UDP to Cloudflare is blocked on the MCI firewall, which is the network this
/// whole feature exists for, so the lookup fails and the handshake never gets a
/// key. The resolver is selectable, but only through this variable.
///
/// DoH rather than `tcp://`: it rides 443 alongside everything else, where
/// plain DNS over TCP on 53 is as blockable as the UDP it replaces.
///
/// Dart cannot write to [Platform.environment], which is a snapshot, so this
/// goes through libc. Harmless to call more than once and called before the
/// core is opened, which is the only ordering that matters: the core reads the
/// variable when a job asks for ECH, not at load time.
abstract final class AetherEnv {
  /// Cloudflare's DoH endpoint by address, so this needs no name resolved
  /// before it can resolve a name.
  static const String kEchDns = 'https://1.1.1.1/dns-query';

  static bool _done = false;

  /// Whether [apply] has run and the libc call returned success.
  @visibleForTesting
  static bool get appliedForTest => _applied;
  static bool _applied = false;

  static void apply() {
    if (_done) return;
    _done = true;
    _set('AETHER_ECH_DNS', kEchDns);
  }

  static void _set(String key, String value) {
    final Pointer<Utf8> k = key.toNativeUtf8();
    final Pointer<Utf8> v = value.toNativeUtf8();
    try {
      final DynamicLibrary lib = Platform.isWindows
          ? DynamicLibrary.open('msvcrt.dll')
          : DynamicLibrary.process();
      final int rc = Platform.isWindows
          ? lib.lookupFunction<_PutenvC, _Putenv>('_putenv_s')(k, v)
          : lib.lookupFunction<_SetenvC, _Setenv>('setenv')(k, v, 1);
      _applied = rc == 0;
      if (rc != 0) {
        NovaLog.instance.write('Could not set $key for the WARP core (rc $rc); '
            'it will look its ECH key up over UDP, which some networks block.');
      }
    } catch (e) {
      // Never fatal: without it ECH falls back to the core's own default, which
      // works on every network that does not block UDP to Cloudflare.
      NovaLog.instance.write('Could not set $key for the WARP core ($e).');
    } finally {
      calloc.free(k);
      calloc.free(v);
    }
  }
}
