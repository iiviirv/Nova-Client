import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;

import 'aether_options.dart';
import 'aether_protocol.dart';

/// The `dart:ffi` binding to the Aether core.
///
/// Every entry point has the same shape: it takes UTF-8 JSON (or nothing) and
/// returns a heap-allocated C string the caller must hand back to
/// `aether_string_free`. Forgetting that leaks on every scan tick, which on a
/// poll loop is a leak with a clock on it, so the reading and freeing live in
/// one place here rather than at each call site.
///
/// Long work does not block: it returns a job id to poll. That is what allows a
/// scan to show progress and be cancelled instead of freezing a screen for the
/// two minutes a thorough sweep can take.
typedef _StrFn = Pointer<pkg_ffi.Utf8> Function();
typedef _StrFnC = Pointer<pkg_ffi.Utf8> Function();

typedef _FreeC = Void Function(Pointer<pkg_ffi.Utf8>);
typedef _Free = void Function(Pointer<pkg_ffi.Utf8>);

typedef _JsonInC = Pointer<pkg_ffi.Utf8> Function(Pointer<pkg_ffi.Utf8>);
typedef _JsonIn = Pointer<pkg_ffi.Utf8> Function(Pointer<pkg_ffi.Utf8>);

typedef _IdC = Pointer<pkg_ffi.Utf8> Function(Uint64);
typedef _Id = Pointer<pkg_ffi.Utf8> Function(int);

typedef _IdJsonC = Pointer<pkg_ffi.Utf8> Function(Uint64, Pointer<pkg_ffi.Utf8>);
typedef _IdJson = Pointer<pkg_ffi.Utf8> Function(int, Pointer<pkg_ffi.Utf8>);

/// Thrown when the library is not present or is missing an entry point, which
/// is a packaging problem rather than anything the user did.
class AetherUnavailable implements Exception {
  AetherUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'The Aether core is unavailable: $reason';
}

class AetherCore {
  AetherCore._(this._lib);

  final DynamicLibrary _lib;
  static AetherCore? _instance;

  /// Opens the library, once per process.
  ///
  /// Android loads it from the APK's native lib directory by name. The desktop
  /// builds sit beside the executable, the same place the sing-box core does.
  static AetherCore open() {
    final AetherCore? existing = _instance;
    if (existing != null) return existing;
    try {
      final DynamicLibrary lib = switch (Platform.operatingSystem) {
        'android' => DynamicLibrary.open('libaether.so'),
        'linux' => DynamicLibrary.open('libaether.so'),
        'macos' => DynamicLibrary.open('libaether.dylib'),
        'windows' => DynamicLibrary.open('aether.dll'),
        _ => throw AetherUnavailable(
            'no build for ${Platform.operatingSystem}'),
      };
      return _instance = AetherCore._(lib);
    } on ArgumentError catch (e) {
      throw AetherUnavailable('the library could not be loaded ($e)');
    }
  }

  /// True when the core can be loaded at all, so a caller can hide the feature
  /// instead of offering something that will fail.
  static bool get available {
    try {
      open();
      return true;
    } catch (_) {
      return false;
    }
  }

  late final _Free _free =
      _lib.lookupFunction<_FreeC, _Free>('aether_string_free');

  /// Reads a reply out of the core and frees it. Every call goes through here
  /// so no path can forget the free.
  AetherReply _take(Pointer<pkg_ffi.Utf8> p) {
    if (p == nullptr) {
      return AetherReply.parse(null);
    }
    try {
      return AetherReply.parse(p.toDartString());
    } finally {
      _free(p);
    }
  }

  R _withJson<R>(String json, R Function(Pointer<pkg_ffi.Utf8>) body) {
    final Pointer<pkg_ffi.Utf8> p = json.toNativeUtf8();
    try {
      return body(p);
    } finally {
      pkg_ffi.calloc.free(p);
    }
  }

  /// The core's version, and the cheapest proof it is really loaded.
  String? version() {
    final AetherReply r = _take(
        _lib.lookupFunction<_StrFnC, _StrFn>('aether_version')());
    return r.ok ? (r['version']?.toString() ?? r['result']?.toString()) : null;
  }

  /// Opens (or creates) the WARP identity. Everything else needs its handle.
  ///
  /// Asynchronous: the reply carries a job id, and the identity handle arrives
  /// in that job's result. [dir] is a directory; the core names the file itself
  /// per transport.
  AetherReply identityOpen(AetherOptions o, {required String dir}) =>
      identityOpenRaw(AetherPayloads.identity(o, dir: dir));

  /// The same call with a payload built elsewhere, for tests that want to send
  /// something deliberately wrong.
  AetherReply identityOpenRaw(String payloadJson) => _withJson(
      payloadJson,
      (Pointer<pkg_ffi.Utf8> p) => _take(_lib
          .lookupFunction<_JsonInC, _JsonIn>('aether_identity_open')(p)));

  /// Starts a scan. Returns a job id in `job`.
  AetherReply scanStart(int identity, AetherOptions o,
          {List<String> excluded = const <String>[]}) =>
      _withJson(
          AetherPayloads.scan(o, excluded: excluded),
          (Pointer<pkg_ffi.Utf8> p) => _take(_lib
              .lookupFunction<_IdJsonC, _IdJson>('aether_scan_start')(
              identity, p)));

  /// Opens a real tunnel to prove an endpoint carries traffic. Returns a job id.
  AetherReply verifyStart(int identity, AetherOptions o,
          {required String socks}) =>
      _withJson(
          AetherPayloads.tunnel(o, socks: socks),
          (Pointer<pkg_ffi.Utf8> p) => _take(_lib
              .lookupFunction<_IdJsonC, _IdJson>('aether_verify_start')(
              identity, p)));

  /// Brings the tunnel up for real, serving SOCKS5 on [socks].
  AetherReply tunnelStart(int identity, AetherOptions o,
          {required String socks}) =>
      _withJson(
          AetherPayloads.tunnel(o, socks: socks),
          (Pointer<pkg_ffi.Utf8> p) => _take(_lib
              .lookupFunction<_IdJsonC, _IdJson>('aether_tunnel_start')(
              identity, p)));

  /// Where a job has got to.
  AetherJobStatus jobPoll(int job) {
    final Pointer<pkg_ffi.Utf8> p =
        _lib.lookupFunction<_IdC, _Id>('aether_job_poll')(job);
    if (p == nullptr) return AetherJobStatus.parse(null);
    try {
      return AetherJobStatus.parse(p.toDartString());
    } finally {
      _free(p);
    }
  }

  /// Stops a job. Used by the cancel button on a scan, which otherwise runs for
  /// the whole sweep budget whatever the user does.
  AetherReply jobCancel(int job) =>
      _take(_lib.lookupFunction<_IdC, _Id>('aether_job_cancel')(job));
}
