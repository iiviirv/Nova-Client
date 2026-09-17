import 'dart:async';
import 'dart:io';

/// One address on this device that another device on the network can use to
/// reach the local proxy, as measured rather than assumed.
class LanShareEndpoint {
  const LanShareEndpoint({
    required this.address,
    required this.port,
    required this.asksForLogin,
  });

  final String address;
  final int port;

  /// Whether the running proxy refused a SOCKS5 greeting that offered no login.
  final bool asksForLogin;

  String get hostPort => '$address:$port';
}

/// What the dashboard can truthfully say about the shared proxy.
///
/// Settings only say what the next connection will do. The running core was
/// built from whatever Settings said at connect time, so the only honest way
/// to know whether other devices can get in right now is to knock on the
/// port from this device's own network address.
class LanShareProbe {
  const LanShareProbe._();

  /// Swappable so widget tests do not depend on the machine's interfaces.
  static Future<List<String>> Function() listAddresses = privateIpv4Addresses;

  /// Swappable for the same reason. Null means nothing answered on that
  /// address, true means it wants a login, false means it let us in without one.
  static Future<bool?> Function(String host, int port) knock = socksKnock;

  static Future<({bool hasAddress, List<LanShareEndpoint> reachable})> run(
      int port) async {
    final List<String> addrs = await listAddresses();
    final List<LanShareEndpoint> out = <LanShareEndpoint>[];
    for (final String a in addrs) {
      final bool? login = await knock(a, port);
      if (login == null) continue;
      out.add(LanShareEndpoint(address: a, port: port, asksForLogin: login));
    }
    return (hasAddress: addrs.isNotEmpty, reachable: out);
  }

  // Interfaces whose private addresses other devices on the user's network
  // cannot reach: tunnels (including Nova's own), container and VM networks,
  // and the cellular links, where carriers hand out 10.x addresses of their own.
  //
  // macOS bridge100 stays in on purpose: it is also what Internet Sharing
  // uses, which is a real way to hand this connection to another device.
  // Everything that survives is knocked on anyway, so a stray extra address
  // costs a line on the card, while a wrongly skipped one would tell the user
  // there is no network when there is.
  static const List<String> _skipPrefixes = <String>[
    'tun', 'utun', 'tap', 'wg', 'ipsec', 'ppp', 'docker', 'br-', 'veth',
    'vmnet', 'vboxnet', 'virbr', 'vethernet (wsl', 'vethernet (default switch',
    'rmnet', 'ccmni', 'pdp_ip', 'llw', 'awdl',
  ];

  /// More than this and the card turns into a list nobody reads.
  static const int _maxShown = 3;

  static Future<List<String>> privateIpv4Addresses() async {
    final List<NetworkInterface> ifs;
    try {
      ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } on Object {
      return const <String>[];
    }
    final List<String> found = <String>[];
    for (final NetworkInterface i in ifs) {
      final String name = i.name.toLowerCase();
      if (_skipPrefixes.any(name.startsWith)) continue;
      for (final InternetAddress a in i.addresses) {
        if (a.isLoopback || !isPrivateIpv4(a.address)) continue;
        if (!found.contains(a.address)) found.add(a.address);
      }
    }
    // Home routers overwhelmingly hand out 192.168.x, so that goes first when
    // a machine is on more than one network.
    found.sort((String a, String b) => _rank(a).compareTo(_rank(b)));
    return found.take(_maxShown).toList();
  }

  static int _rank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    return 2;
  }

  static bool isPrivateIpv4(String ip) {
    final List<int>? o = _octets(ip);
    if (o == null) return false;
    if (o[0] == 10) return true;
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
    return o[0] == 192 && o[1] == 168;
  }

  static List<int>? _octets(String ip) {
    final List<String> parts = ip.split('.');
    if (parts.length != 4) return null;
    final List<int> o = <int>[];
    for (final String p in parts) {
      final int? n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
      o.add(n);
    }
    return o;
  }

  /// Opens the port on [host] and offers a SOCKS5 greeting with no login.
  ///
  /// The mixed inbound answers SOCKS5 on the same port as HTTP, and it replies
  /// 0x00 (go ahead) when it has no users and 0xFF (no acceptable method) when
  /// it has. An answer that is not SOCKS5 at all counts as open, because
  /// telling someone a port is locked when it might not be is the worse error.
  static Future<bool?> socksKnock(String host, int port) async {
    Socket? s;
    try {
      s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 2));
      s.add(const <int>[0x05, 0x01, 0x00]);
      final List<int> reply = await _readAtLeast(s, 2);
      if (reply.length >= 2 && reply[0] == 0x05) return reply[1] != 0x00;
      return false;
    } on Object {
      // Refused or timed out before connecting: nothing is listening there
      // for other devices. Anything after the connect: something is.
      return s == null ? null : false;
    } finally {
      s?.destroy();
    }
  }

  // The two reply bytes are not guaranteed to arrive in one read, and taking
  // only the first chunk would call a locked port open.
  static Future<List<int>> _readAtLeast(Socket s, int n) {
    final List<int> got = <int>[];
    final Completer<List<int>> done = Completer<List<int>>();
    late final StreamSubscription<List<int>> sub;
    void finish() {
      if (!done.isCompleted) done.complete(got);
    }

    sub = s.listen(
      (List<int> chunk) {
        got.addAll(chunk);
        if (got.length >= n) finish();
      },
      onError: (Object _) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
    return done.future
        .timeout(const Duration(seconds: 2), onTimeout: () => got)
        .whenComplete(sub.cancel);
  }
}
