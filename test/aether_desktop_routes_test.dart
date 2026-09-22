import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/aether/aether_desktop_routes.dart';

void main() {
  for (final gateway in ['162.159.198.36', '2606:4700:100::1']) {
    test('excludes only the chosen gateway $gateway and keeps existing routes',
        () {
      final config = <String, dynamic>{
        'inbounds': [
          {'type': 'mixed'},
          {
            'type': 'tun',
            'route_exclude_address': ['10.0.0.0/8']
          },
        ]
      };
      excludeAetherGateway(config, gateway);
      excludeAetherGateway(config, gateway);
      expect(
          config['inbounds'][0].containsKey('route_exclude_address'), isFalse);
      expect(config['inbounds'][1]['route_exclude_address'],
          ['10.0.0.0/8', '$gateway/${gateway.contains(':') ? 128 : 32}']);
    });
  }
  test('proxy mode gains no excluded routes', () {
    final config = <String, dynamic>{
      'inbounds': [
        {'type': 'mixed'}
      ]
    };
    excludeAetherGateway(config, '162.159.198.36');
    expect(config['inbounds'][0], {'type': 'mixed'});
  });
  test('a hostname cannot become an invalid OS route', () {
    expect(() => excludeAetherGateway({'inbounds': []}, 'example.com'),
        throwsFormatException);
  });
}
