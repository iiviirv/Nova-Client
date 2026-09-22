import 'dart:io';

/// Keep the external Aether engine's gateway off the macOS packet tunnel.
/// A sing-box direct rule still captures and relays the socket; an OS route
/// exclusion lets the engine own its connection and return path end to end.
void excludeAetherGateway(Map<String, dynamic> config, String gateway) {
  final address =
      InternetAddress.tryParse(gateway.replaceAll(RegExp(r'^\[|\]$'), ''));
  if (address == null) {
    throw const FormatException('Aether gateway must be an IP address');
  }
  final cidr =
      '${address.address}/${address.type == InternetAddressType.IPv4 ? 32 : 128}';
  for (final inbound in config['inbounds'] as List<dynamic>) {
    if (inbound['type'] != 'tun') continue;
    final existing = (inbound['route_exclude_address'] as List<dynamic>?) ?? [];
    inbound['route_exclude_address'] =
        <String>{...existing.cast<String>(), cidr}.toList();
  }
}
