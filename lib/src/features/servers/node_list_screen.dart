import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/proxy_profile.dart';
import '../../core/proxy/proxy_controller.dart';
import '../../core/proxy/singbox/proxy_node.dart';
import '../../core/proxy/subscription.dart';
import '../../widgets/nova_scope.dart';

const Color _accent = Color(0xFF7C5CFF);

/// Lists the nodes of a subscription with a live TCP latency for each, and lets
/// the user pin a specific exit (or fall back to auto-select). Pinning updates
/// the profile and reconnects through the chosen node — this is the "switch to
/// a better IP" control.
class NodeListScreen extends StatefulWidget {
  const NodeListScreen({super.key, required this.profileId});

  final String profileId;

  @override
  State<NodeListScreen> createState() => _NodeListScreenState();
}

class _NodeListScreenState extends State<NodeListScreen> {
  /// Cap how many nodes we display + ping, so a 1000-node subscription stays
  /// responsive. They're deduped by server:port first.
  static const int _maxShown = 80;

  List<ProxyNode> _nodes = <ProxyNode>[];
  final Map<String, int> _ping = <String, int>{}; // key -> ms (-1 = unreachable)
  bool _loading = true;
  String? _error;

  String _key(ProxyNode n) => '${n.server}:${n.port}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  ProxyProfile? get _profile {
    final list = NovaScope.of(context).profiles.profiles;
    for (final p in list) {
      if (p.id == widget.profileId) return p;
    }
    return null;
  }

  Future<void> _load() async {
    final profiles = NovaScope.of(context).profiles;
    final profile = _profile;
    if (profile == null) {
      setState(() {
        _loading = false;
        _error = 'Profile not found';
      });
      return;
    }
    try {
      final all = await resolveProfileNodes(profile);
      // Dedupe by server:port and cap.
      final seen = <String>{};
      final deduped = <ProxyNode>[];
      for (final n in all) {
        if (seen.add(_key(n))) deduped.add(n);
        if (deduped.length >= _maxShown) break;
      }
      // Keep the real node count on the profile so the cards stop saying "1".
      profiles.update(profile.copyWith(nodeCount: all.length));
      if (!mounted) return;
      setState(() {
        _nodes = deduped;
        _loading = false;
      });
      _pingAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load nodes: $e';
      });
    }
  }

  Future<void> _pingAll() async {
    // Bounded concurrency so we don't open 80 sockets at once.
    const int batch = 12;
    for (int i = 0; i < _nodes.length; i += batch) {
      final slice = _nodes.skip(i).take(batch);
      await Future.wait(slice.map(_pingOne));
      if (!mounted) return;
      setState(() {});
    }
  }

  Future<void> _pingOne(ProxyNode n) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(n.server, n.port,
          timeout: const Duration(seconds: 3));
      sw.stop();
      s.destroy();
      _ping[_key(n)] = sw.elapsedMilliseconds;
    } catch (_) {
      _ping[_key(n)] = -1;
    }
  }

  Future<void> _pin(String? key) async {
    final scope = NovaScope.of(context);
    final profile = _profile;
    if (profile == null) return;
    final updated = profile.copyWith(pinnedNode: key);
    scope.profiles.update(updated);
    scope.profiles.setActive(updated.id);
    scope.proxy.selectProfile(updated);
    // If the tunnel is up, re-establish it through the new exit.
    final st = scope.proxy.state;
    if (st == ProxyConnectionState.connected ||
        st == ProxyConnectionState.connecting) {
      await scope.proxy.disconnect();
      await scope.proxy.connect();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final sorted = <ProxyNode>[..._nodes]..sort((a, b) {
        final pa = _ping[_key(a)] ?? 9999;
        final pb = _ping[_key(b)] ?? 9999;
        final na = pa < 0 ? 100000 : pa;
        final nb = pb < 0 ? 100000 : pb;
        return na.compareTo(nb);
      });
    final pinned = profile?.pinnedNode;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.name ?? 'Nodes'),
        actions: <Widget>[
          if (!_loading)
            IconButton(
              tooltip: 'Re-test',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _ping.clear();
                setState(() {});
                _pingAll();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  children: <Widget>[
                    _AutoRow(
                      selected: pinned == null,
                      onTap: () => _pin(null),
                    ),
                    const Divider(height: 1),
                    for (final n in sorted)
                      _NodeRow(
                        node: n,
                        ms: _ping[_key(n)],
                        selected: pinned == _key(n),
                        onTap: () => _pin(_key(n)),
                      ),
                  ],
                ),
    );
  }
}

class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bolt, color: _accent),
      title: const Text('Auto (fastest)'),
      subtitle: const Text('Let Nova pick the lowest-latency node'),
      trailing: selected
          ? const Icon(Icons.check_circle, color: _accent)
          : null,
      onTap: onTap,
    );
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.node,
    required this.ms,
    required this.selected,
    required this.onTap,
  });

  final ProxyNode node;
  final int? ms;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String name = node.tag.isNotEmpty ? node.tag : node.server;
    return ListTile(
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${node.server}:${node.port}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _PingBadge(ms: ms),
          if (selected) ...<Widget>[
            const SizedBox(width: 10),
            const Icon(Icons.check_circle, color: _accent, size: 20),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}

class _PingBadge extends StatelessWidget {
  const _PingBadge({required this.ms});
  final int? ms;

  @override
  Widget build(BuildContext context) {
    if (ms == null) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (ms! < 0) {
      return Text('timeout',
          style: TextStyle(color: Colors.red.shade400, fontSize: 12));
    }
    final Color c = ms! < 150
        ? Colors.green.shade400
        : ms! < 350
            ? Colors.amber.shade400
            : Colors.orange.shade400;
    return Text('$ms ms',
        style: TextStyle(color: c, fontWeight: FontWeight.w600));
  }
}
