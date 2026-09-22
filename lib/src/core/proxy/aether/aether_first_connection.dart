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

  Future<ProxyProfile?> prepare(ProxyProfile profile) async {
    final config = AetherConfig.parse(profile.uri);
    if (profile.kind != ProxyKind.aether ||
        config == null ||
        (config.gateway?.isNotEmpty ?? false)) {
      return profile;
    }
    cancel();
    final generation = _generation;
    final search = _createSearch();
    _search = search;
    try {
      final found = await search.run(config.options, (_) {});
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
