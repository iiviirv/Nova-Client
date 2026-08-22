import 'dart:async';

import '../../features/radar/models.dart';
import '../../features/radar/scanner.dart';
import '../../features/radar/sources.dart';
import '../logging/nova_log.dart';
import 'clean_ip_store.dart';

/// Finds a Cloudflare address that is reachable from THIS device.
///
/// A thin wrapper over the Radar scanner Nova already ships. Radar exists to be
/// driven by hand from its own screen, with a wide sample and a long run; this
/// runs it small and quietly in the background, because all it has to produce
/// is one good address rather than a browsable list.
class CleanIpFinder {
  CleanIpFinder._();

  /// A deliberately small slice of Cloudflare's space. The goal is one working
  /// address in a few seconds on a phone, not the best address in existence.
  /// Radar's own screen is still there for anyone who wants to hunt properly.
  static const int kSampleSize = 128;

  /// Only ports Nova can actually front a node on, cheapest first.
  static const List<int> kPorts = <int>[443, 2053, 8443];

  static NovaScanner? _running;

  /// Runs a scan and stores the best address it finds. Returns it, or null if
  /// nothing answered (a network where even Cloudflare is unreachable, or a
  /// scan that was stopped).
  static Future<CleanIp?> find({
    int sampleSize = kSampleSize,
    Duration budget = const Duration(seconds: 45),
  }) async {
    final CleanIpStore store = CleanIpStore.instance;
    if (!store.beginSearch()) return null;
    final NovaScanner scanner = NovaScanner(
      sampleSize: sampleSize,
      quickTimeout: const Duration(seconds: 2),
      deepTimeout: const Duration(seconds: 3),
    );
    _running = scanner;
    try {
      NovaLog.instance.write('Looking for a clean address on this network');
      final List<ScanResult> results = await scanner
          .start(
            // Cloudflare's own published ranges only. The other Radar sources
            // are off by default and are not what a fronted node needs.
            sources: defaultSources()
                .where((IpSource s) => s.id == 'official')
                .toList(),
            ports: kPorts,
          )
          .timeout(budget, onTimeout: () {
        scanner.stop();
        return const <ScanResult>[];
      });
      if (results.isEmpty) {
        NovaLog.instance.write('No clean address answered on this network');
        return null;
      }
      // start() returns them sorted, best first.
      final ScanResult best = results.first;
      final CleanIp found = CleanIp(
        ip: best.ip,
        port: best.port,
        latencyMs: best.latencyMs,
        foundAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      // Persisting is a convenience, not the result. A storage failure once
      // threw the address away and reported that nothing was found, which read
      // as "this network has no clean addresses" when the scan had in fact
      // succeeded in two seconds.
      try {
        await store.record(found);
      } catch (e) {
        NovaLog.instance.write('Could not save the clean address: $e',
            level: NovaLogLevel.warn);
        store.hold(found);
      }
      return found;
    } catch (e) {
      NovaLog.instance.write('Clean address search failed: $e');
      return null;
    } finally {
      _running = null;
      store.endSearch();
      unawaited(scanner.dispose());
    }
  }

  /// Stops an in-flight search, for example when the user connects and the core
  /// needs the bandwidth more than the scan does.
  static void stop() => _running?.stop();

  /// The address to front with: whatever is stored and still fresh, else a scan
  /// if one is worth starting. Returns null rather than blocking a connect on a
  /// scan that may take half a minute.
  static CleanIp? current() => CleanIpStore.instance.fresh;

  /// Kicks off a search if there is no fresh address and none is running. Never
  /// awaited by the connect path: the first connect goes out unfronted and the
  /// next one benefits.
  static void ensure() {
    if (CleanIpStore.instance.fresh != null) return;
    if (CleanIpStore.instance.searching) return;
    unawaited(find());
  }
}
