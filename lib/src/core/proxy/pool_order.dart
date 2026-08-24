import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'singbox/proxy_node.dart';

/// Gives each install its own order for Nova's free list.
///
/// The list is published in one fixed order, every device sweeps it in that
/// order, and the sweep stops once it has enough working servers. So every
/// device found the SAME servers: the ones at the top. A few volunteer servers
/// carried every Nova user while the rest of the list sat unused, and the
/// reward for being near the top of the file was being the first to fall over.
///
/// Shuffling per install spreads that load across the whole pool at no cost.
/// It is not load balancing, which would need something the client cannot see;
/// it is just the removal of an accidental agreement between every device to
/// pick the same servers.
///
/// The order is stable for an install rather than random per run, because a
/// list that reorders itself every time it is opened is its own problem: the
/// server someone picked yesterday should be where they left it.
class PoolOrder {
  PoolOrder._();

  static const String _kSeed = 'nova.poolSeed';
  static SharedPreferences? _prefs;
  static int? _seed;

  static Future<void> load() async {
    try {
      // Fetched, not cached with ??=: load() runs once at startup, and holding
      // the first instance for ever makes the seed impossible to observe
      // changing, which hid a bug where two installs produced the same order.
      _prefs = await SharedPreferences.getInstance();
      int? s = _prefs!.getInt(_kSeed);
      if (s == null) {
        // Any value will do as long as installs disagree.
        s = Random().nextInt(1 << 31);
        await _prefs!.setInt(_kSeed, s);
      }
      _seed = s;
    } catch (_) {
      // Without a stored seed the order falls back to the published one, which
      // is the old behaviour: worse for load, never wrong.
    }
  }

  /// The install's seed, or null before [load] or if storage failed.
  static int? get seed => _seed;

  /// [nodes] in this install's own order. Returns the input untouched when no
  /// seed is available, so a storage failure costs spread rather than function.
  static List<ProxyNode> shuffled(List<ProxyNode> nodes) {
    final int? s = _seed;
    if (s == null || nodes.length < 2) return nodes;
    final List<ProxyNode> out = List<ProxyNode>.of(nodes);
    out.shuffle(Random(s));
    return out;
  }
}
