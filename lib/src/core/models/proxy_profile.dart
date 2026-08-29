import 'dart:convert';

import '../proxy/singbox/awg_config.dart';

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
  // Added 2026-08-19: single links of these schemes used to be saved under
  // whatever pill was selected (a hysteria2:// link became a "Subscription"),
  // which mislabelled the row and muddled the add flow's kind logic. New
  // values go at the end: persisted profiles store the enum by name, so
  // order is free, but unknown names in an old build fall back to vless.
  hysteria2,
  vmess,
  tuic,
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
        ProxyKind.hysteria2 => 'Hysteria2',
        ProxyKind.vmess => 'VMess',
        ProxyKind.tuic => 'TUIC',
      };
}

extension ProxyProfileBadge on ProxyProfile {
  /// What the badge on this profile reads.
  ///
  /// For AmneziaWG that is the protocol plus the generation the server offers,
  /// so a config says "AMNEZIAWG VER 3" wherever it appears, not only inside a
  /// subscription's node list. A config that identifies no version, and every
  /// other protocol, is just the protocol name.
  String get badgeLabel {
    if (kind != ProxyKind.awg) return kind.label;
    final String? v = awgVersionLabel(uri.isNotEmpty ? uri : subscriptionUrl);
    return v == null ? kind.label : '${kind.label} ver $v';
  }
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
    this.pinnedName,
    this.fastNodes = const <String>[],
    this.hardenTls = false,
    this.encryptedOnly = false,
    this.bypassFingerprint,
    this.bypassCipherSuites,
    this.bypassFragmentMask,
    this.telegramProxy,
    this.telegramProxyWeb,
    this.hardenTlsUserSet = false,
  });

  final String id;
  final String name;
  final ProxyKind kind;

  /// The share link (e.g. `vless://…`) or, for subscriptions, the active node.
  final String uri;

  /// Source URL when [kind] is [ProxyKind.subscription].
  final String? subscriptionUrl;

  /// Number of nodes resolved from a subscription (1 for single links).
  /// The Telegram proxy a subscription advertises (`nova.telegramProxy`), as
  /// the `tg://` link that hands it to the Telegram app. Null for a
  /// subscription that publishes none, and every non-subscription profile.
  final String? telegramProxy;

  /// The web fallback for [telegramProxy], used only when the device has no
  /// Telegram app to take the `tg://` link. Never the primary action: it opens
  /// a page showing a proxy the reader cannot add.
  final String? telegramProxyWeb;

  /// Whether the user has decided about [hardenTls] themselves.
  ///
  /// A subscription can ask for the bypass on by default (`nova.sniBlockBypass`)
  /// because the operator knows it sits behind a network that blocks the domain.
  /// That is a default, not a lock: once the user has set the switch either way,
  /// this is true and a later refresh must leave their choice alone.
  final bool hardenTlsUserSet;

  final int nodeCount;

  /// Most recent measured latency, if probed.
  final int? lastLatencyMs;

  final DateTime? updatedAt;

  /// For a subscription, the `server:port` of a manually pinned exit node, or
  /// null to let the core auto-pick the fastest (urltest).
  final String? pinnedNode;

  /// The panel's name for the pinned node. A subscription that rotates its clean
  /// IPs changes a node's address (and so its [pinnedNode] key) on every refresh,
  /// which would silently break the pin and drop the user onto a different exit.
  /// Matching on this stable name as a fallback keeps the chosen server pinned
  /// across those rotations.
  final String? pinnedName;

  /// Nova's own free list, which the user did not add and cannot remove. It is
  /// the fallback that makes "install it and press Connect" true, including for
  /// someone who has just deleted everything else.
  bool get isBuiltIn => id == kFreeProfileId;

  /// Drop any server from this subscription whose traffic is not encrypted (see
  /// [ProxyNode.isEncrypted]). Set on the free list Nova ships, where the whole
  /// promise is that someone can install the app, press Connect and be safe
  /// without reading a single config. A subscription the user added themselves
  /// is left exactly as their provider sent it.
  final bool encryptedOnly;

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

  /// User overrides for the SNI-block bypass, edited from the bypass editor so a
  /// tester can re-tune the anti-DPI recipe when filtering changes. Each is null
  /// to use Nova's field-tested default (`unsafe` fingerprint, [kBypassCipherSuites],
  /// [kBypassFragmentMask]).
  final String? bypassFingerprint;
  final List<String>? bypassCipherSuites;
  final String? bypassFragmentMask;

  bool get isSubscription => kind == ProxyKind.subscription;

  ProxyProfile copyWith({
    String? telegramProxyWeb,
    bool? hardenTlsUserSet,
    String? telegramProxy,
    String? name,
    String? uri,
    String? subscriptionUrl,
    int? nodeCount,
    Object? lastLatencyMs = _unset,
    DateTime? updatedAt,
    Object? pinnedNode = _unset,
    Object? pinnedName = _unset,
    List<String>? fastNodes,
    bool? hardenTls,
    bool? encryptedOnly,
    Object? bypassFingerprint = _unset,
    Object? bypassCipherSuites = _unset,
    Object? bypassFragmentMask = _unset,
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
      pinnedName:
          pinnedName == _unset ? this.pinnedName : pinnedName as String?,
      fastNodes: fastNodes ?? this.fastNodes,
      hardenTls: hardenTls ?? this.hardenTls,
      encryptedOnly: encryptedOnly ?? this.encryptedOnly,
      bypassFingerprint: bypassFingerprint == _unset
          ? this.bypassFingerprint
          : bypassFingerprint as String?,
      bypassCipherSuites: bypassCipherSuites == _unset
          ? this.bypassCipherSuites
          : bypassCipherSuites as List<String>?,
      telegramProxy: telegramProxy ?? this.telegramProxy,
        telegramProxyWeb: telegramProxyWeb ?? this.telegramProxyWeb,
        hardenTlsUserSet: hardenTlsUserSet ?? this.hardenTlsUserSet,
        bypassFragmentMask: bypassFragmentMask == _unset
          ? this.bypassFragmentMask
          : bypassFragmentMask as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (telegramProxy != null) 'telegramProxy': telegramProxy,
        if (telegramProxyWeb != null) 'telegramProxyWeb': telegramProxyWeb,
        if (hardenTlsUserSet) 'hardenTlsUserSet': true,
        'id': id,
        'name': name,
        'kind': kind.name,
        'uri': uri,
        'subscriptionUrl': subscriptionUrl,
        'nodeCount': nodeCount,
        'lastLatencyMs': lastLatencyMs,
        'updatedAt': updatedAt?.toIso8601String(),
        'pinnedNode': pinnedNode,
        'pinnedName': pinnedName,
        'fastNodes': fastNodes,
        'hardenTls': hardenTls,
        'encryptedOnly': encryptedOnly,
        'bypassFingerprint': bypassFingerprint,
        'bypassCipherSuites': bypassCipherSuites,
        'bypassFragmentMask': bypassFragmentMask,
      };

  factory ProxyProfile.fromJson(Map<String, dynamic> json) => ProxyProfile(
        telegramProxy: json['telegramProxy'] as String?,
        telegramProxyWeb: json['telegramProxyWeb'] as String?,
        hardenTlsUserSet: json['hardenTlsUserSet'] as bool? ?? false,
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
        pinnedName: json['pinnedName'] as String?,
        fastNodes: (json['fastNodes'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[],
        hardenTls: json['hardenTls'] as bool? ?? false,
        encryptedOnly: json['encryptedOnly'] as bool? ?? false,
        bypassFingerprint: json['bypassFingerprint'] as String?,
        bypassCipherSuites: (json['bypassCipherSuites'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList(),
        bypassFragmentMask: json['bypassFragmentMask'] as String?,
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

/// The list of free servers Nova ships, so someone can install the app, press
/// Connect and be online without owning a subscription or pasting a link.
///
/// It is an ordinary subscription profile with two things set for it:
/// [ProxyProfile.encryptedOnly], so a plaintext entry that finds its way into
/// the upstream list is never offered; and [ProxyProfile.hardenTls], the
/// SNI-block bypass, because the people who most need a free list are on the
/// networks that block the ordinary handshake.
const String kFreeSubUrl =
    'https://raw.githubusercontent.com/IRNova/Tools/refs/heads/main/sub.txt';

/// Fixed id, so the free list is recognisable across launches: it is only ever
/// seeded once, and removing it is a decision the user gets to keep.
const String kFreeProfileId = 'nova-free';

ProxyProfile buildFreeProfile({String name = 'Nova free servers'}) => ProxyProfile(
      id: kFreeProfileId,
      name: name,
      kind: ProxyKind.subscription,
      uri: kFreeSubUrl,
      subscriptionUrl: kFreeSubUrl,
      nodeCount: 0,
      hardenTls: true,
      encryptedOnly: true,
    );
