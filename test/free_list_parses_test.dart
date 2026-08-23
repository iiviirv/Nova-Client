import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/models/proxy_profile.dart';
import 'package:nova_client/src/core/proxy/singbox/proxy_node.dart';
import 'package:nova_client/src/core/proxy/singbox/share_link.dart';
import 'package:nova_client/src/core/proxy/subscription.dart';

/// Guards the published free list against the two ways it can be wrong on the
/// device even when every server works: an entry Nova cannot parse, and an
/// entry Nova parses but then filters out as unencrypted. Either one is a line
/// that costs a user a server for no reason.
void main() {
  test('every published entry parses and survives the free-list filter', () {
    final String path = Platform.environment['NOVA_FREELIST'] ?? '';
    if (path.isEmpty || !File(path).existsSync()) {
      return; // only runs when pointed at a generated list
    }
    final List<String> lines = File(path)
        .readAsLinesSync()
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, isNotEmpty);

    final List<String> unparsed = <String>[];
    final List<ProxyNode> nodes = <ProxyNode>[];
    for (final String l in lines) {
      final ProxyNode? n = parseShareLink(l);
      if (n == null) {
        unparsed.add(l);
      } else {
        nodes.add(n);
      }
    }
    for (final String u in unparsed) {
      // ignore: avoid_print
      print('UNPARSED: ${u.length > 150 ? u.substring(0, 150) : u}');
    }
    expect(unparsed, isEmpty,
        reason: '${unparsed.length} of ${lines.length} entries do not parse');

    final List<ProxyNode> kept =
        applyProfileFilters(buildFreeProfile(), nodes);
    expect(kept.length, nodes.length,
        reason: 'the encryptedOnly filter would drop '
            '${nodes.length - kept.length} published entries on the device');
    // ignore: avoid_print
    print('free list: ${lines.length} entries, all parse, all survive filtering');
  });
}
