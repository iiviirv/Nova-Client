// Filters a candidate list down to servers that actually carry traffic.
//
// Reachability is not usefulness. A TCP connect and a TLS handshake both
// succeed against a parked Cloudflare hostname that proxies nothing, and the
// public aggregators this list is built from are full of exactly that: of a
// 58-server sample that passed both checks, 12 carried traffic. Publishing on
// the strength of a handshake would ship a list that looks large and mostly
// fails on the device, which is the failure the previous hand-made list had.
//
// So the shipped core is what decides. Each candidate is dialled through
// sing-box and has to return a real HTTP response before it is published.
//
// Usage: NOVA_FREELIST=candidates.txt NOVA_OUT=verified.txt \
//          flutter test tool/verify/verify_freelist_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/measure_runner.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/singbox/singbox_config.dart';

/// Nodes per core instance, capped by the measuring pool budget
/// (SingboxConfig.kMeasurePoolCap): anything above it is silently dropped from
/// the pool and would be recorded as "did not answer" without ever being dialled.
const int kBatch = SingboxConfig.kMeasurePoolCap;

void main() {
  test('keep only servers that carry traffic', _verify,
      timeout: const Timeout(Duration(minutes: 45)));
}

String _coreBinary() {
  final String base = '${Directory.current.path}/assets/bin';
  if (Platform.isMacOS) {
    return '$base/sing-box-macos-${Platform.version.contains('arm64') ? 'arm64' : 'arm64'}';
  }
  return Platform.environment['NOVA_CORE'] ?? '$base/sing-box-linux-amd64';
}

Future<void> _verify() async {
  // flutter_test blocks real sockets by default; this test is entirely about
  // using the real network.
  HttpOverrides.global = null;

  final String path = Platform.environment['NOVA_FREELIST'] ?? '';
  final String out = Platform.environment['NOVA_OUT'] ?? '';
  if (path.isEmpty || out.isEmpty) {
    fail('set NOVA_FREELIST and NOVA_OUT');
  }
  final List<String> links = File(path)
      .readAsLinesSync()
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();

  final String bin = Platform.environment['NOVA_CORE'] ?? _coreBinary();
  if (!File(bin).existsSync()) fail('core not found at $bin');

  final List<String> kept = <String>[];
  final List<int> allMs = <int>[];
  int tested = 0;

  for (int start = 0; start < links.length; start += kBatch) {
    final List<String> slice =
        links.sublist(start, (start + kBatch).clamp(0, links.length));
    final List<ProxyNode> nodes = <ProxyNode>[];
    final List<String> src = <String>[];
    for (final String l in slice) {
      final ProxyNode? n = parseShareLink(l);
      if (n != null) {
        nodes.add(n);
        src.add(l);
      }
    }
    if (nodes.isEmpty) continue;

    final int mixed = 24080 + (start ~/ kBatch) * 2;
    final int clash = mixed + 1;
    final ({Map<String, dynamic> config, Map<String, String> tagKeys}) built =
        SingboxConfig.buildMeasureMap(nodes,
            mixedPort: mixed, clashPort: clash);

    final Directory tmp = Directory.systemTemp.createTempSync('novaverify');
    final File cf = File('${tmp.path}/config.json')
      ..writeAsStringSync(jsonEncode(built.config));
    // buildMeasureMap still emits the pre-1.12 DNS block and the CLI core
    // treats that as fatal, not a warning. The desktop controller sets the same
    // variable. (Typed-DNS migration is owed before sing-box 1.14 drops it.)
    final Process p = await Process.start(
      bin,
      <String>['run', '-c', cf.path],
      environment: <String, String>{
        'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
      },
    );
    p.stderr.transform(utf8.decoder).listen((String s) {
      if (s.contains('FATAL') || s.contains('panic')) stderr.write(s);
    });

    final Uri api = Uri.parse('http://127.0.0.1:$clash');
    final bool ready =
        await MeasureRunner.waitForApi(api, timeout: const Duration(seconds: 40));
    if (!ready) {
      stderr.writeln('batch at $start: core never came up, skipping');
      p.kill();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      continue;
    }

    final Map<String, int> got = await MeasureRunner.run(
      api: api,
      tagKeys: built.tagKeys,
      url: 'HTTP://www.gstatic.com/generate_204',
      timeoutSec: 12,
    );
    p.kill();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}

    // Match results by the stable node key rather than by position. The pool
    // filters and can reorder (xhttp is dropped, hardening rewrites nodes), so
    // an index into the input list is not the same node the core measured.
    final Map<String, String> linkOfKey = <String, String>{};
    for (int i = 0; i < nodes.length; i++) {
      linkOfKey[proxyNodeKey(nodes[i])] = src[i];
    }
    got.forEach((String key, int ms) {
      final String? link = linkOfKey[key];
      if (link != null && ms > 0) {
        kept.add(link);
        allMs.add(ms);
      }
    });
    tested += nodes.length;
    stderr.writeln('batch ${start ~/ kBatch}: tested ${nodes.length}, '
        'kept ${kept.length} of $tested so far');
  }

  allMs.sort();
  stderr.writeln('--- verified through the core ---');
  stderr.writeln('tested $tested, carry traffic: ${kept.length}');
  if (allMs.isNotEmpty) {
    stderr.writeln('median ${allMs[allMs.length ~/ 2]}ms, best ${allMs.first}ms');
  }
  File(out).writeAsStringSync(kept.join('\n') + (kept.isEmpty ? '' : '\n'));
  expect(kept, isNotEmpty, reason: 'no server carried traffic');
}
