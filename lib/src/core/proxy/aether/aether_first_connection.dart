import 'package:flutter/foundation.dart';

import '../../models/proxy_profile.dart';
import '../../../features/servers/aether_gateway_search.dart';
import 'aether_options.dart';

/// Discovers once, keeping the effective fallback settings with the gateway.
/// Cancellation invalidates even a result that arrives after the native stop.
class AetherFirstConnection {
  /// Defaults to the adaptive search, not the plain core one.
  ///
  /// Field log, 2026-09-23: a free MASQUE profile scanned for 120 seconds on
  /// h3 and never tried the HTTP/2 fallback, because the fallback lives in
  /// [AetherAdaptiveSearch] and only the Aether editor was building one. The
  /// path almost everyone takes, tapping Connect on a built-in profile, came
  /// through here and got a plain [AetherCoreSearch]. So the automatic MASQUE
  /// HTTP/2 fallback shipped in 1.26.0 could not fire for the users it was
  /// written for, on the networks it was written for.
  AetherFirstConnection({AetherGatewaySearch Function()? createSearch})
      : _createSearch = createSearch ?? AetherAdaptiveSearch.new;

  final AetherGatewaySearch Function() _createSearch;

  /// Which search this would build. Exposed so a test can prove the wiring,
  /// which is the part that was wrong, rather than the search's own logic,
  /// which was already covered and already correct.
  @visibleForTesting
  AetherGatewaySearch createSearchForTest() => _createSearch();
  AetherGatewaySearch? _search;
  int _generation = 0;

  void cancel() {
    ++_generation;
    _search?.cancel();
    _search = null;
  }

  Future<ProxyProfile?> prepare(
    ProxyProfile profile, {
    bool replace = false,
    void Function(AetherSearchProgress)? onProgress,
  }) async {
    final config = AetherConfig.parse(profile.uri);
    if (profile.kind != ProxyKind.aether ||
        config == null ||
        (!replace && (config.gateway?.isNotEmpty ?? false))) {
      return profile;
    }
    cancel();
    final generation = _generation;
    final search = _createSearch();
    _search = search;
    try {
      final options = replace
          ? AetherOptions.fromQuery(config.options.toQuery())
          : config.options;
      // Tagged with the protocol from here down, because this is the only layer
      // that knows it: the search takes options, and the dashboard card takes
      // progress. A MASQUE search runs far longer than the other two, and the
      // card cannot say so unless the progress carries which one is running.
      onProgress?.call(AetherSearchProgress(
          attempt: 1, verifying: false, ruledOut: 0, mode: options.mode));
      final found = await search.run(options, (progress) {
        if (generation == _generation) {
          onProgress?.call(progress.withMode(options.mode));
        }
      },
          excludedFirst:
              replace && config.gateway != null ? [config.gateway!] : const []);
      if (generation != _generation || search.cancelled) return null;
      if (!found.ok) {
        throw FormatException(
            found.error ?? 'No working Aether gateway found. Try again.');
      }
      return profile.copyWith(
        uri: AetherConfig(
          options:
              (found.options ?? config.options).copyWith(peer: found.endpoint),
          name: config.name,
        ).toLink(),
        updatedAt: DateTime.now(),
      );
    } catch (_) {
      if (generation != _generation) return null;
      rethrow;
    } finally {
      if (identical(_search, search)) _search = null;
    }
  }
}
