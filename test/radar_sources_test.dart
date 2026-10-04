import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/radar/models.dart';
import 'package:nova_client/src/features/radar/sources.dart';

int _ipToInt(String ip) {
  final parts = ip.split('.').map(int.parse).toList();
  return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

void main() {
  group('generateRandomIps', () {
    test('produces unique IPs inside the requested CIDR', () {
      const cidr = '104.16.0.0/13';
      final ips = generateRandomIps(<String>[cidr], 200);

      expect(ips, isNotEmpty);
      expect(ips.length, lessThanOrEqualTo(200));
      expect(ips.toSet().length, ips.length, reason: 'IPs should be unique');

      // 104.16.0.0/13 spans 104.16.0.0 .. 104.23.255.255
      final start = _ipToInt('104.16.0.0');
      final end = _ipToInt('104.23.255.255');
      for (final ip in ips) {
        final v = _ipToInt(ip);
        expect(v, greaterThanOrEqualTo(start));
        expect(v, lessThanOrEqualTo(end));
      }
    });

    test('spreads across multiple CIDRs', () {
      final ips = generateRandomIps(
        <String>['192.0.2.0/24', '198.51.100.0/24'],
        100,
      );
      final hasFirst = ips.any((ip) => ip.startsWith('192.0.2.'));
      final hasSecond = ips.any((ip) => ip.startsWith('198.51.100.'));
      expect(hasFirst || hasSecond, isTrue);
    });

    test('returns empty for no CIDRs', () {
      expect(generateRandomIps(<String>[], 50), isEmpty);
    });
  });

  group('default sources', () {
    test('match the NovaRadar source set, plus the IPv6 one', () {
      final sources = defaultSources();
      expect(sources, hasLength(10));
      expect(sources.first.id, 'official');
      expect(sources.first.enabled, isTrue);
      // Two enabled by default now, not one. Cloudflare's v6 list joined the
      // v4 one on 2026-10-04, when the six-packet WebSocket cap arrived on
      // IPv4 only and IPv6 became one of the few routes left on that network.
      // Everything else is still opt-in.
      final enabled = sources.where((s) => s.enabled).toList();
      expect(enabled.map((s) => s.id), <String>['official', 'official6']);
    });

    test('the IPv6 source points at the v6 list, not the v4 one', () {
      final v6 = defaultSources().firstWhere((s) => s.id == 'official6');
      expect(v6.url, endsWith('/ips-v6/'),
          reason: 'pointing this at the v4 list would quietly scan nothing new');
      expect(v6.type, SourceType.cidr);
    });
  });

  group('port groups', () {
    test('TLS ports are a subset of all ports', () {
      expect(kTlsPorts.every(kAllPorts.contains), isTrue);
      expect(kAllPorts, contains(443));
      expect(kAllPorts, contains(8080));
    });
  });
}
