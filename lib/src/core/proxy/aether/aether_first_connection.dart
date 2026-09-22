import '../../models/proxy_profile.dart';
import '../../../features/servers/aether_gateway_search.dart';
import 'aether_options.dart';

/// Discovers once, keeping the effective fallback settings with the gateway.
/// Cancellation invalidates even a result that arrives after the native stop.
class AetherFirstConnection {
  AetherFirstConnection({AetherGatewaySearch Function()? createSearch})
      : _createSearch = createSearch ?? (() => AetherCoreSearch());

  final AetherGatewaySearch Function() _createSearch;
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
      onProgress?.call(const AetherSearchProgress(
          attempt: 1, verifying: false, ruledOut: 0));
      final options = replace
          ? AetherOptions.fromQuery(config.options.toQuery())
          : config.options;
      final found = await search.run(options, (progress) {
        if (generation == _generation) onProgress?.call(progress);
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
