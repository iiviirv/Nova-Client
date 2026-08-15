import 'dart:convert';

/// The proxy protocols Nova Proxy speaks (mirrors the Nova Worker: VLESS,
/// Trojan, Shadowsocks over WebSocket/gRPC/XHTTP) plus the subscription and
/// local-config kinds Karing-style clients import.
enum ProxyKind {
  vless,
  trojan,
  shadowsocks,
  subscription,
  singboxConfig,
  awg,
  socks,
  http,
}

/// Sentinel so [ProxyProfile.copyWith] can distinguish "leave pinnedNode as is"
/// from "clear it to null" (back to auto-select).
const Object _unset = Object();

extension ProxyKindLabel on ProxyKind {
  String get label => switch (this) {
        ProxyKind.vless => 'VLESS',
        ProxyKind.trojan => 'Trojan',
        ProxyKind.shadowsocks => 'Shadowsocks',
        ProxyKind.subscription => 'Subscription',
        ProxyKind.singboxConfig => 'sing-box',
        ProxyKind.awg => 'AmneziaWG',
        ProxyKind.socks => 'SOCKS',
        ProxyKind.http => 'HTTP',
      };
}

/// A connection profile — either a single node link or a subscription URL that
/// expands into many nodes. Persisted as JSON via [shared_preferences].
class ProxyProfile {
  ProxyProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.uri,
    this.subscriptionUrl,
    this.nodeCount = 1,
    this.lastLatencyMs,
    this.updatedAt,
    this.pinnedNode,
    this.fastNodes = const <String>[],
    this.hardenTls = false,
  });

  final String id;
  final String name;
  final ProxyKind kind;

  /// The share link (e.g. `vless://…`) or, for subscriptions, the active node.
  final String uri;

  /// Source URL when [kind] is [ProxyKind.subscription].
  final String? subscriptionUrl;

  /// Number of nodes resolved from a subscription (1 for single links).
  final int nodeCount;

  /// Most recent measured latency, if probed.
  final int? lastLatencyMs;

  final DateTime? updatedAt;

  /// For a subscription, the `server:port` of a manually pinned exit node, or
  /// null to let the core auto-pick the fastest (urltest).
  final String? pinnedNode;

  /// `server:port` keys of the fastest measured nodes (from the node picker's
  /// latency test), best first. Auto-select builds its urltest pool from these
  /// so "fastest" actually uses good nodes instead of the subscription's first
  /// few. Empty until the user opens the node list.
  final List<String> fastNodes;

  /// The SNI-block bypass profile is applied to this profile's clean-IP fronted
  /// nodes (see `SingboxRouteOptions.hardenTls`). Off by default; turned on by
  /// Nova itself when every node in the subscription fails to carry traffic
  /// (the signature of a network that blocks the worker's SNI), or by the user
  /// from the node list. Sticky once on, until the user turns it off.
  final bool hardenTls;

  bool get isSubscription => kind == ProxyKind.subscription;

  ProxyProfile copyWith({
    String? name,
    String? uri,
    String? subscriptionUrl,
    int? nodeCount,
    Object? lastLatencyMs = _unset,
    DateTime? updatedAt,
    Object? pinnedNode = _unset,
    List<String>? fastNodes,
    bool? hardenTls,
  }) {
    return ProxyProfile(
      id: id,
      name: name ?? this.name,
      kind: kind,
      uri: uri ?? this.uri,
      subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      nodeCount: nodeCount ?? this.nodeCount,
      lastLatencyMs:
          lastLatencyMs == _unset ? this.lastLatencyMs : lastLatencyMs as int?,
      updatedAt: updatedAt ?? this.updatedAt,
      pinnedNode:
          pinnedNode == _unset ? this.pinnedNode : pinnedNode as String?,
      fastNodes: fastNodes ?? this.fastNodes,
      hardenTls: hardenTls ?? this.hardenTls,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.name,
        'uri': uri,
        'subscriptionUrl': subscriptionUrl,
        'nodeCount': nodeCount,
        'lastLatencyMs': lastLatencyMs,
        'updatedAt': updatedAt?.toIso8601String(),
        'pinnedNode': pinnedNode,
        'fastNodes': fastNodes,
        'hardenTls': hardenTls,
      };

  factory ProxyProfile.fromJson(Map<String, dynamic> json) => ProxyProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: ProxyKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => ProxyKind.vless,
        ),
        uri: json['uri'] as String? ?? '',
        subscriptionUrl: json['subscriptionUrl'] as String?,
        nodeCount: json['nodeCount'] as int? ?? 1,
        lastLatencyMs: json['lastLatencyMs'] as int?,
        updatedAt: json['updatedAt'] != null
            ? DateTime.tryParse(json['updatedAt'] as String)
            : null,
        pinnedNode: json['pinnedNode'] as String?,
        fastNodes: (json['fastNodes'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        hardenTls: json['hardenTls'] as bool? ?? false,
      );

  static String encodeList(List<ProxyProfile> profiles) =>
      jsonEncode(profiles.map((p) => p.toJson()).toList());

  static List<ProxyProfile> decodeList(String raw) {
    final List<dynamic> data = jsonDecode(raw) as List<dynamic>;
    return data
        .map((e) => ProxyProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
