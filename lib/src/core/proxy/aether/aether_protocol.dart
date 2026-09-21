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
      return const AetherReply._(
          false, 'the core returned nothing', <String, dynamic>{});
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return AetherReply._(
          false,
          'the core returned something that is not JSON',
          <String, dynamic>{'raw': raw});
    }
    if (decoded is! Map) {
      return const AetherReply._(
          false, 'the core returned a bare value', <String, dynamic>{});
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

  bool get isFailed => state == AetherJobState.failed;

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
  static String scan(AetherOptions o,
          {List<String> excluded = const <String>[]}) =>
      jsonEncode(<String, dynamic>{
        'transport': _transport(o),
        'mode': o.mode.name,
        ..._fragment(o),
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
  /// HTTP/2 and fragment fields require Nova's patched core. Upstream's
  /// original FFI maps both h2 and h3 to MASQUE and reads process-wide CLI
  /// environment variables instead; merely sending those strings is not
  /// sufficient. See tool/core/aether-h2-fragment.patch.
  static String tunnel(AetherOptions o,
          {required String endpoint, required String socks}) =>
      jsonEncode(<String, dynamic>{
        'peer': endpoint,
        'transport': _transport(o),
        // The core's transport has only two values, Masque and WireGuard, and
        // anything it does not recognise becomes Masque. So "gool" parses as
        // Masque, and without the mode alongside it a gool tunnel is a plain
        // MASQUE tunnel wearing a gool label: it connects, which is why it
        // reads as working, while not being what the config says.
        //
        // The scan has always carried mode. Dropping it here was wrong.
        'mode': o.mode.name,
        ..._fragment(o),
        if (o.noize != null) 'profile': o.noize!.name,
        'socks': socks,
      });

  /// The transport the core understands, which is not the same as the mode.
  ///
  /// Its enum has exactly two values and anything unrecognised becomes Masque:
  ///
  ///     "wg" | "wireguard" | "warp" => WireGuard,  _ => Masque
  ///
  /// So gool must say "wg". It is WARP inside WARP, WireGuard nested in
  /// WireGuard, and the nesting is selected by the mode sent alongside. Sending
  /// "gool" here fell through to Masque, which made a gool config scan MASQUE
  /// endpoints and build a MASQUE tunnel. It connected, so it read as working,
  /// and a tester confirmed three of them as good; they were all MASQUE.
  ///
  /// Measured rather than reasoned: a gool search returned 162.159.198.2:443,
  /// the same MASQUE gateway and port as a plain MASQUE search, where WireGuard
  /// returned 188.114.98.211:939.
  /// The transport, for callers that need it outside a payload.
  ///
  /// iOS hands the tunnel to the Network Extension, which has to open the
  /// identity itself because only it knows its own container path. It needs the
  /// transport to do that, and taking it from here keeps one answer to what the
  /// transport is rather than a second opinion in Swift.
  static Map<String, dynamic> _fragment(AetherOptions o) =>
      o.mode == AetherMode.masque && o.transport == AetherTransport.h2
          ? <String, dynamic>{
              'fragment': o.fragment,
              'fragment_size': o.effectiveFragmentSize,
              'fragment_delay': o.effectiveFragmentDelay,
            }
          : const <String, dynamic>{};

  static String transportOf(AetherOptions o) => _transport(o);

  static String _transport(AetherOptions o) {
    if (o.mode == AetherMode.masque) {
      return o.transport == AetherTransport.h2 ? 'h2' : 'h3';
    }
    // Both wg and gool ride WireGuard; the mode says which.
    return 'wg';
  }
}

/// A gateway address, in the one shape everything else expects.
///
/// The core does not hand endpoints back as strings. A scan returns
/// `{ip: 162.159.198.1, port: 443, rtt_ms: 617}`, while the tunnel payload's
/// `peer` and the scan payload's `excluded` both want "ip:port". Calling
/// toString on the map produces "{ip: ..., port: ..., rtt_ms: ...}", which the
/// core refuses with "is not an address:port".
///
/// That refusal was the visible half. The quiet half was worse: the same
/// stringified maps went into `excluded`, where they matched nothing, so the
/// retry kept rediscovering the address it had just rejected. The automatic
/// retry looked like it was working and was not.
class AetherEndpoint {
  /// Normalises whatever the core returned into "ip:port", or null when it is
  /// not an endpoint at all.
  static String? parse(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      final String v = raw.trim();
      return v.isEmpty ? null : v;
    }
    if (raw is Map) {
      final Object? ip = raw['ip'] ?? raw['address'] ?? raw['host'];
      final Object? port = raw['port'];
      if (ip == null || port == null) return null;
      final String host = ip.toString().trim();
      if (host.isEmpty) return null;
      // An IPv6 literal needs brackets before a port can be appended, or the
      // colons of the address run into the colon of the port.
      final String shown =
          host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
      return '$shown:$port';
    }
    return null;
  }
}
