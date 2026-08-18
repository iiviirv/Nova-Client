import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/node_probe.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

void main() {
  final String subscriptionUrl =
      Platform.environment['NOVA_LIVE_SUB_URL'] ?? '';

  test(
    'a live Nova subscription contains nodes with measurable latency',
    () async {
      final ProxyProfile profile = ProxyProfile(
        id: 'live-ping',
        name: 'Live Nova',
        kind: ProxyKind.subscription,
        uri: '',
        subscriptionUrl: subscriptionUrl,
      );

      final nodes = await resolveProfileNodes(profile);
      expect(nodes, isNotEmpty);

      final sample = nodes.take(12).toList();
      final results = await Future.wait(
        sample.map(
          (node) async => (
            node: node,
            probe: await probeNode(
              node,
              timeout: const Duration(seconds: 5),
            ),
          ),
        ),
      );
      final measured = results.where((result) => result.probe.ok).toList();

      for (final result in results) {
        // Safe diagnostic output: endpoint and SNI only, never credentials.
        // The tier matters as much as the number: "handshake" means the server
        // answered but nothing was carried through it.
        // ignore: avoid_print
        print(
          '${result.node.server}:${result.node.port} '
          'sni=${result.node.sni ?? '-'} '
          '${result.probe.quality.name} '
          'latency=${result.probe.latencyMs?.toString() ?? '-'} '
          '${result.probe.reason ?? ''}',
        );
      }

      expect(
        measured,
        isNotEmpty,
        reason: 'no sampled Nova node could be proven reachable',
      );
    },
    skip: subscriptionUrl.isEmpty
        ? 'Set NOVA_LIVE_SUB_URL to run the live diagnostic.'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
