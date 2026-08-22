import 'dart:io';

/// Cloudflare's published IPv4 ranges.
///
/// The same list Radar falls back to when no source returns CIDRs. It lives
/// here as well because two different questions need it: which addresses to
/// scan for a clean IP, and whether a server someone handed us is behind
/// Cloudflare at all. It changes rarely, and being a release behind costs at
/// most a missed substitution, never a wrong one.
const List<String> kCloudflareV4Cidrs = <String>[
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
];

/// The ports Cloudflare terminates TLS on, and so the only ports a fronted
/// node can be reached through. A server on 8080 is not going through
/// Cloudflare whatever its address resolves to.
const Set<int> kCloudflareTlsPorts = <int>{
  443,
  2053,
  2083,
  2087,
  2096,
  8443,
};

/// Whether [ip] (an IPv4 literal) sits in one of Cloudflare's ranges.
bool isCloudflareIp(String ip) {
  final InternetAddress? addr = InternetAddress.tryParse(ip);
  if (addr == null || addr.type != InternetAddressType.IPv4) return false;
  final int value = _toInt(addr.rawAddress);
  for (final String cidr in kCloudflareV4Cidrs) {
    if (_inCidr(value, cidr)) return true;
  }
  return false;
}

int _toInt(List<int> octets) =>
    (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3];

bool _inCidr(int value, String cidr) {
  final int slash = cidr.indexOf('/');
  if (slash < 0) return false;
  final InternetAddress? base = InternetAddress.tryParse(cidr.substring(0, slash));
  final int? bits = int.tryParse(cidr.substring(slash + 1));
  if (base == null || bits == null || bits < 0 || bits > 32) return false;
  if (bits == 0) return true;
  final int mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
  return (_toInt(base.rawAddress) & mask) == (value & mask);
}
