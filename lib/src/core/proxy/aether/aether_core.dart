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

/// The key the identity handle arrives under in an opened identity's job
/// result. Confirmed on a device: the result is
/// `{identity: 2, summary: {...}, path: ..., ok: true}`.
///
/// Named here rather than probed for. The search used to try several likely
/// keys and then any lone integer, which worked but would have kept working
/// while quietly meaning something else if the shape ever changed.
const String kAetherIdentityField = 'identity';

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
      final String name = switch (Platform.operatingSystem) {
        'android' || 'linux' => 'libaether.so',
        'macos' => 'libaether.dylib',
        'windows' => 'aether.dll',
        _ => throw AetherUnavailable(
            'no build for ${Platform.operatingSystem}'),
      };
      // Android resolves by name from the APK's extracted lib directory. On
      // desktop the library sits beside the app the same way the sing-box core
      // does, and the plain name only works if that directory happens to be on
      // the loader's path, which it is not when running from source. So the
      // known locations are tried first and the bare name is the fallback.
      for (final String path in _candidatePaths(name)) {
        try {
          return _instance = AetherCore._(DynamicLibrary.open(path));
        } catch (_) {
          // Try the next location.
        }
      }
      throw AetherUnavailable('$name was not found beside the app');
    } on ArgumentError catch (e) {
      throw AetherUnavailable('the library could not be loaded ($e)');
    }
  }

  /// Where the library might be, best first. Mirrors how the desktop core
  /// binary is located, including the assets/bin fallback that makes
  /// `flutter run` from a checkout work.
  static Iterable<String> _candidatePaths(String name) sync* {
    if (Platform.isAndroid) {
      yield name;
      return;
    }
    final Directory exeDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      yield '${exeDir.parent.path}/Resources/$name';
    } else if (Platform.isWindows) {
      yield '${exeDir.path}\\$name';
    } else if (Platform.isLinux) {
      yield '${exeDir.path}/$name';
      yield '${exeDir.path}/lib/$name';
    }
    yield 'assets/bin/$name';
    yield name;
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
  /// in that job's result under [kAetherIdentityField]. [base] is a path prefix
  /// the core appends the transport to.
  AetherReply identityOpen(AetherOptions o, {required String base}) =>
      identityOpenRaw(AetherPayloads.identity(o, base: base));

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
          {required String endpoint, required String socks}) =>
      _withJson(
          AetherPayloads.tunnel(o, endpoint: endpoint, socks: socks),
          (Pointer<pkg_ffi.Utf8> p) => _take(_lib
              .lookupFunction<_IdJsonC, _IdJson>('aether_verify_start')(
              identity, p)));

  /// Brings the tunnel up for real, serving SOCKS5 on [socks].
  AetherReply tunnelStart(int identity, AetherOptions o,
          {required String endpoint, required String socks}) =>
      _withJson(
          AetherPayloads.tunnel(o, endpoint: endpoint, socks: socks),
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
