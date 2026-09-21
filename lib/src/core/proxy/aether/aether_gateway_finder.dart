import 'aether_options.dart';
import 'aether_protocol.dart';

/// Finding a gateway that actually carries traffic, without making the user do
/// it again.
///
/// The core's scan returns one endpoint, and an endpoint that answered a probe
/// is not the same as one that will carry traffic. In another client that gap
/// is the user's problem: the scan succeeds, the tunnel does not come up, and
/// the fix is to run the whole scan by hand and hope for a different address.
///
/// The core already offers the two pieces needed to close that: a verify call
/// that opens a real tunnel, and an `excluded` list on the scan. So scan,
/// verify, and if verification fails, scan again with that endpoint excluded.
/// Without the exclusion a re-scan tends to return the same address, which is
/// exactly why the manual retry feels like a coin flip.
///
/// Verified endpoints are kept rather than discarded, so a later connection has
/// somewhere to fall back to instead of starting over.
class AetherGatewayFinder {
  AetherGatewayFinder({
    required this.scan,
    required this.verify,
    this.attempts = 4,
  });

  /// Runs one scan, excluding what has already been ruled out. Returns the
  /// endpoint, or null with a reason.
  final Future<AetherJobStatus> Function(
      AetherOptions options, List<String> excluded) scan;

  /// Opens a real tunnel to one endpoint and reports whether traffic moved.
  final Future<AetherJobStatus> Function(AetherOptions options, String endpoint)
      verify;

  /// How many gateways to try before giving up. Four because each attempt costs
  /// a scan and a real tunnel, and a user watching a spinner has a limit.
  final int attempts;

  /// The endpoints ruled out this run, in order.
  final List<String> rejected = <String>[];

  /// The endpoints that carried traffic, best first.
  final List<String> verified = <String>[];

  /// Finds a working gateway, or explains why it could not.
  Future<AetherFindResult> find(AetherOptions options) async {
    String? lastError;
    for (int i = 0; i < attempts; i++) {
      final AetherJobStatus found =
          await scan(options, List<String>.of(rejected));
      if (found.state != AetherJobState.done) {
        // A scan that found nothing will not find something on a retry with one
        // more address excluded, so this stops rather than burning the budget.
        return AetherFindResult(
            endpoint: null,
            error: found.error ?? 'the scan found no gateway',
            attempts: i + 1,
            rejected: List<String>.of(rejected));
      }
      // Normalised, not stringified. The core returns an object here, and
      // toString on it yields something no later call accepts.
      final String? endpoint = AetherEndpoint.parse(found.result?['endpoint']);
      if (endpoint == null || endpoint.isEmpty) {
        return AetherFindResult(
            endpoint: null,
            error: 'the scan returned no address',
            attempts: i + 1,
            rejected: List<String>.of(rejected));
      }
      final AetherJobStatus proof = await verify(options, endpoint);
      // A finished verification is not a passed one. The core returns
      // {"reachable": <bool>}, and the job succeeds either way: `ok` says the
      // check ran, `reachable` says what it found. Reading only the state
      // accepts an endpoint the core has just reported as unreachable, which
      // is a gateway that saves, connects, and then sits on "verifying"
      // forever. Reported from Iran as configs that had to be rebuilt.
      //
      // Same mistake as the nested job envelope, one level up: the outer
      // success is about whether the question was answered, not what the
      // answer was.
      if (proof.state == AetherJobState.done &&
          proof.result?['reachable'] != false) {
        if (!verified.contains(endpoint)) verified.add(endpoint);
        return AetherFindResult(
            endpoint: endpoint,
            attempts: i + 1,
            rejected: List<String>.of(rejected));
      }
      lastError = proof.error ??
          (proof.result?['reachable'] == false
              ? 'the gateway answered but carried no traffic'
              : 'the tunnel did not carry traffic');
      if (!rejected.contains(endpoint)) rejected.add(endpoint);
    }
    return AetherFindResult(
        endpoint: null,
        error: lastError ?? 'no gateway carried traffic',
        attempts: attempts,
        rejected: List<String>.of(rejected));
  }
}

/// What a search found, and what it cost.
class AetherFindResult {
  const AetherFindResult({
    required this.endpoint,
    required this.attempts,
    required this.rejected,
    this.error,
    this.options,
  });

  /// The working gateway, or null when none was found.
  final String? endpoint;

  /// The settings that actually proved the endpoint, including fallback.
  final AetherOptions? options;

  /// Why not, when [endpoint] is null.
  final String? error;

  /// How many gateways were tried, so the UI can say "on the third address"
  /// rather than leaving a long wait unexplained.
  final int attempts;

  /// What was ruled out, which is worth keeping: an address that failed once
  /// is worth skipping next time too.
  final List<String> rejected;

  bool get ok => endpoint != null;
}
