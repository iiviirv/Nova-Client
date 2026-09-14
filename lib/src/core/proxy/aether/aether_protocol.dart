// (doc comment above belongs to this library)
import 'dart:convert';

import 'aether_options.dart';

/// The wire protocol of the Aether core's C API: what we send it and how to
/// read what comes back. Kept apart from the `dart:ffi` binding so all of it
/// can be tested without the library present, which is most of the logic.
///
/// Every call returns one JSON string in the same envelope: `{"ok": true, ...}`
/// with the fields merged in, or `{"ok": false, "error": "..."}`.
///
/// The part worth being careful about: long-running work returns a job id, and
/// polling that job returns an envelope whose `result` is ITSELF an envelope.
/// So a poll can succeed while the work inside it failed, and code that checks
/// only the outer `ok` reads a failed scan as a success and then wonders why
/// there is no endpoint.
/// One reply from the core.
class AetherReply {
  const AetherReply._(this.ok, this.error, this.fields);

  final bool ok;
  final String? error;
  final Map<String, dynamic> fields;

  Object? operator [](String key) => fields[key];

  /// Parses a reply. A null, empty, or unparseable string is an error rather
  /// than an exception: the caller is usually in a UI path and needs something
  /// to show, not a crash.
  static AetherReply parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const AetherReply._(false, 'the core returned nothing', <String, dynamic>{});
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return AetherReply._(false, 'the core returned something that is not JSON',
          <String, dynamic>{'raw': raw});
    }
    if (decoded is! Map) {
      return const AetherReply._(false, 'the core returned a bare value', <String, dynamic>{});
    }
    final Map<String, dynamic> m = decoded.cast<String, dynamic>();
    final bool ok = m['ok'] == true;
    return AetherReply._(
      ok,
      ok ? null : (m['error']?.toString() ?? 'the core did not say why'),
      m,
    );
  }
}

/// Where a job has got to.
enum AetherJobState { running, done, failed }

/// The outcome of polling a job.
class AetherJobStatus {
  const AetherJobStatus(this.state, {this.result, this.error});

  final AetherJobState state;

  /// The job's own fields, when it finished successfully.
  final Map<String, dynamic>? result;

  /// Why it failed, whether the poll itself failed or the work did.
  final String? error;

  bool get isRunning => state == AetherJobState.running;

  /// Reads a poll reply, unwrapping the nested envelope.
  ///
  /// Three outcomes hide in two layers here: the poll failed; the poll
  /// succeeded and the job is still running; the poll succeeded, the job
  /// finished, and the job itself either worked or did not.
  static AetherJobStatus parse(String? raw) {
    final AetherReply outer = AetherReply.parse(raw);
    if (!outer.ok) {
      return AetherJobStatus(AetherJobState.failed, error: outer.error);
    }
    if (outer['state'] == 'running') {
      return const AetherJobStatus(AetherJobState.running);
    }
    final Object? inner = outer['result'];
    if (inner is! Map) {
      return const AetherJobStatus(AetherJobState.failed,
          error: 'the job finished without saying what happened');
    }
    final Map<String, dynamic> r = inner.cast<String, dynamic>();
    if (r['ok'] != true) {
      return AetherJobStatus(AetherJobState.failed,
          error: r['error']?.toString() ?? 'the job failed without saying why');
    }
    return AetherJobStatus(AetherJobState.done, result: r);
  }
}

/// The payloads the core expects, built from a config.
class AetherPayloads {
  /// For `aether_identity_open`.
  ///
  /// [base] is a path PREFIX, not a directory and not a file. The core appends
  /// the transport to it, so passing `.../aether` produces `.../aether-masque`
  /// alongside `.../aether-masque-lastconn`, and the WireGuard modes keep their
  /// own files beside those.
  ///
  /// Both halves of that were learned from the core rather than guessed. Its
  /// refusal named the field ("missing field `path`"), and a device run showed
  /// what it does with the value: an earlier version of this comment called it
  /// a directory, which would have had callers creating one for no reason.
  ///
  /// The call is asynchronous like the others: it returns a job id to poll, not
  /// a handle. Treating it as immediate gets a job number where an identity was
  /// expected, and every later call then fails with "there is no identity".
  static String identity(AetherOptions o, {required String base}) =>
      jsonEncode(<String, dynamic>{
        'path': base,
        'transport': _transport(o),
      });

  /// For `aether_scan_start`.
  ///
  /// [excluded] is what makes a retry different from the first attempt. When a
  /// gateway is found but will not carry traffic, scanning again without
  /// excluding it tends to return the same one, which is why a user ends up
  /// running the scan by hand over and over.
  static String scan(AetherOptions o, {List<String> excluded = const <String>[]}) =>
      jsonEncode(<String, dynamic>{
        'transport': _transport(o),
        'mode': o.mode.name,
        'ip': o.ip.name,
        if (o.noize != null) 'profile': o.noize!.name,
        if (excluded.isNotEmpty) 'excluded': excluded,
      });

  /// For `aether_verify_start` and `aether_tunnel_start`.
  ///
  /// [endpoint] is required and is the gateway to dial, as `ip:port`. This is
  /// the difference between a tunnel and a scan: a scan sweeps for an address,
  /// a tunnel is told one. The first version of this omitted it, which the core
  /// would have refused with "missing field `peer`", the same way it refused an
  /// identity without a path.
  ///
  /// [socks] is the local address to serve on.
  ///
  /// Note what is NOT sent: the core's tunnel payload has no mode or ip field.
  /// Those belong to the search. Sending them is harmless (unknown fields are
  /// ignored) but misleading to read, since it suggests a tunnel re-decides
  /// something it does not.
  static String tunnel(AetherOptions o,
          {required String endpoint, required String socks}) =>
      jsonEncode(<String, dynamic>{
        'peer': endpoint,
        'transport': _transport(o),
        if (o.noize != null) 'profile': o.noize!.name,
        'socks': socks,
      });

  /// The core names the transport, not the mode: the WireGuard modes are not
  /// carried over HTTP at all, and sending an HTTP transport with them is how
  /// a config ends up silently doing something other than what it says.
  static String _transport(AetherOptions o) {
    if (o.mode != AetherMode.masque) return o.mode.name;
    return o.transport == AetherTransport.h2 ? 'h2' : 'h3';
  }
}
