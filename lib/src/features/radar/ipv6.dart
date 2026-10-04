import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Finding clean Cloudflare addresses over IPv6.
///
/// Why this exists, from the field on 2026-10-04: on the MCI firewall
/// (Hamrah Aval, Mokhaberat, Shatel) ClientHello fragmentation is now fully
/// blocked, UDP to Cloudflare is blocked outright, and WebSocket over ALPN
/// http/1.1 is capped at six packets on every non-white Cloudflare domain.
/// That last cap is applied to IPv4 only, and the surviving routes named were
/// IPv6, ECH and XHTTP. So an IPv6 address is not a nicety here, it is one of
/// the few ways left to reach a Cloudflare-fronted server from that network.
///
/// An IPv6 range cannot be enumerated the way a v4 one is. Cloudflare publishes
/// /32s and /48s, which hold 2^96 and 2^80 addresses, so this samples rather
/// than walks, and does the arithmetic in [BigInt] because 128 bits does not
/// fit in an int on any platform Nova runs on.
abstract final class Ipv6 {
  /// Cloudflare's published v6 ranges, the fallback when no source answers.
  /// Mirrors the v4 fallback list in sources.dart and the same reasoning: a
  /// scan that cannot fetch a list is still worth running.
  static const List<String> fallbackCidrs = <String>[
    '2400:cb00::/32',
    '2606:4700::/32',
    '2803:f800::/32',
    '2405:b500::/32',
    '2405:8100::/32',
    '2a06:98c0::/29',
    '2c0f:f248::/32',
  ];

  /// Whether this device has a global IPv6 address it could actually dial from.
  ///
  /// Checked because a scan that cannot work is worse than no scan: every probe
  /// would time out, the run would take its full budget, and the user would be
  /// told nothing was reachable rather than that their network has no IPv6 at
  /// all. Link-local (`fe80::`) and loopback do not count, since neither can
  /// reach Cloudflare.
  static Future<bool> available() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv6,
      );
      for (final NetworkInterface i in ifaces) {
        for (final InternetAddress a in i.addresses) {
          if (isGlobal(a.address)) return true;
        }
      }
      return false;
    } catch (_) {
      // Some platforms refuse the enumeration; treat that as "cannot tell",
      // which is the same answer as no, and costs only the v6 half of a scan.
      return false;
    }
  }

  /// Whether [address] is a v6 address that can route off this machine.
  static bool isGlobal(String address) {
    final InternetAddress? a = InternetAddress.tryParse(address);
    if (a == null || a.type != InternetAddressType.IPv6) return false;
    if (a.isLoopback || a.isLinkLocal) return false;
    final Uint8List raw = a.rawAddress;
    // The unspecified address, which is not an address at all.
    if (raw.every((int b) => b == 0)) return false;
    // Unique-local, fc00::/7: routable inside a site, never to Cloudflare.
    if ((raw[0] & 0xFE) == 0xFC) return false;
    // Link-local, fe80::/10. isLinkLocal already covers this; kept because a
    // parsed address with a zone id has been seen to slip past it.
    if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) return false;
    return true;
  }

  /// The 128-bit value of [address], or null when it is not a v6 address.
  static BigInt? toBigInt(String address) {
    final InternetAddress? a = InternetAddress.tryParse(address);
    if (a == null || a.type != InternetAddressType.IPv6) return null;
    BigInt v = BigInt.zero;
    for (final int b in a.rawAddress) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

  /// The canonical text of a 128-bit value, as Dart writes it.
  static String fromBigInt(BigInt v) {
    final List<int> bytes = List<int>.filled(16, 0);
    BigInt n = v;
    for (int i = 15; i >= 0; i--) {
      bytes[i] = (n & BigInt.from(0xFF)).toInt();
      n = n >> 8;
    }
    return InternetAddress.fromRawAddress(Uint8List.fromList(bytes),
            type: InternetAddressType.IPv6)
        .address;
  }

  /// The first address of [cidr] and how many it holds, or null if it is not a
  /// v6 CIDR. Returned as a pair rather than a range because the count can be
  /// 2^96, which is only a number in [BigInt].
  static (BigInt base, BigInt count)? parseCidr(String cidr) {
    final int slash = cidr.indexOf('/');
    if (slash < 0) return null;
    final int? prefix = int.tryParse(cidr.substring(slash + 1));
    if (prefix == null || prefix < 0 || prefix > 128) return null;
    final BigInt? base = toBigInt(cidr.substring(0, slash).trim());
    if (base == null) return null;
    final BigInt one = BigInt.one;
    final BigInt hostBits = BigInt.from(128 - prefix);
    final BigInt count = one << hostBits.toInt();
    final BigInt mask = ((one << 128) - one) ^ (count - one);
    return (base & mask, count);
  }

  /// Up to [count] random addresses spread across [cidrs].
  ///
  /// Spread rather than clustered: Cloudflare answers on any address in a
  /// range, but a filter that has learned one address has learned its
  /// neighbours too, so drawing them from across the space is the point.
  static List<String> sample(List<String> cidrs, int count, {Random? rng}) {
    if (cidrs.isEmpty || count <= 0) return const <String>[];
    final Random r = rng ?? Random.secure();
    final Set<String> out = <String>{};
    final int perCidr = (count ~/ cidrs.length) + 1;
    for (final String cidr in cidrs) {
      final (BigInt, BigInt)? parsed = parseCidr(cidr);
      if (parsed == null) continue;
      final (BigInt base, BigInt total) = parsed;
      if (total <= BigInt.two) continue;
      for (int j = 0; j < perCidr && out.length < count; j++) {
        // Skip the network address itself, as the v4 generator does.
        out.add(fromBigInt(base + BigInt.one + _below(r, total - BigInt.one)));
      }
      if (out.length >= count) break;
    }
    return out.toList();
  }

  /// A uniform value in [0, bound), built from 32-bit draws because
  /// Random.nextInt tops out well below 128 bits.
  static BigInt _below(Random r, BigInt bound) {
    if (bound <= BigInt.one) return BigInt.zero;
    final int bits = bound.bitLength;
    BigInt v;
    do {
      v = BigInt.zero;
      for (int taken = 0; taken < bits; taken += 32) {
        v = (v << 32) | BigInt.from(r.nextInt(1 << 32));
      }
      v = v & ((BigInt.one << bits) - BigInt.one);
    } while (v >= bound);
    return v;
  }
}
