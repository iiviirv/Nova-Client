/// Data models for Nova Radar — the Cloudflare clean-IP scanner consolidated
/// into Nova Client. Ported from the original NovaRadar Go backend
/// (`IRNova/NovaRadar`: sources.go / scanner.go).

enum SourceType { cidr, proxyip, domain }

extension SourceTypeName on SourceType {
  String get wire => switch (this) {
        SourceType.cidr => 'cidr',
        SourceType.proxyip => 'proxyip',
        SourceType.domain => 'domain',
      };

  static SourceType parse(String s) => switch (s) {
        'proxyip' => SourceType.proxyip,
        'domain' => SourceType.domain,
        _ => SourceType.cidr,
      };
}

/// A selectable source of candidate IPs (a CIDR list, a reverse-proxy IP list,
/// or a list of domains to resolve).
class IpSource {
  IpSource({
    required this.id,
    required this.name,
    required this.url,
    required this.type,
    required this.enabled,
  });

  final String id;
  final String name;
  final String url;
  final SourceType type;
  bool enabled;

  IpSource copyWith({bool? enabled}) => IpSource(
        id: id,
        name: name,
        url: url,
        type: type,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'type': type.wire,
        'enabled': enabled,
      };

  factory IpSource.fromJson(Map<String, dynamic> json) => IpSource(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        type: SourceTypeName.parse(json['type'] as String? ?? 'cidr'),
        enabled: json['enabled'] as bool? ?? false,
      );
}

/// A working IP found by the scanner.
class ScanResult {
  ScanResult({
    required this.ip,
    required this.port,
    required this.link,
    required this.latencyMs,
  });

  final String ip;
  final int port;
  final String link;
  final int latencyMs;

  String get hostPort => '$ip:$port';
}

/// Live scan statistics streamed to the UI (mirrors NovaRadar's ScanStats).
class ScanStats {
  const ScanStats({
    this.totalScanned = 0,
    this.totalToScan = 0,
    this.aliveCount = 0,
    this.deadCount = 0,
    this.scanning = false,
    this.currentIp = '',
    this.currentPort = 0,
    this.elapsedSec = 0,
    this.remainingSec = 0,
    this.secondPass = false,
  });

  final int totalScanned;
  final int totalToScan;
  final int aliveCount;
  final int deadCount;
  final bool scanning;
  final String currentIp;
  final int currentPort;
  final int elapsedSec;
  final int remainingSec;
  final bool secondPass;

  double get progress {
    if (totalToScan == 0) return 0;
    return (totalScanned / totalToScan).clamp(0.0, 1.0).toDouble();
  }

  static const ScanStats idle = ScanStats();

  ScanStats copyWith({
    int? totalScanned,
    int? totalToScan,
    int? aliveCount,
    int? deadCount,
    bool? scanning,
    String? currentIp,
    int? currentPort,
    int? elapsedSec,
    int? remainingSec,
    bool? secondPass,
  }) {
    return ScanStats(
      totalScanned: totalScanned ?? this.totalScanned,
      totalToScan: totalToScan ?? this.totalToScan,
      aliveCount: aliveCount ?? this.aliveCount,
      deadCount: deadCount ?? this.deadCount,
      scanning: scanning ?? this.scanning,
      currentIp: currentIp ?? this.currentIp,
      currentPort: currentPort ?? this.currentPort,
      elapsedSec: elapsedSec ?? this.elapsedSec,
      remainingSec: remainingSec ?? this.remainingSec,
      secondPass: secondPass ?? this.secondPass,
    );
  }
}

/// The TLS ports — these get a real TLS handshake in the deep test; others get
/// a TCP read probe. (From NovaRadar's `tlsPorts`.)
const Set<int> kTlsPorts = <int>{443, 2053, 2083, 2087, 2096, 8443};

/// All ports Nova Radar can probe (TLS group first, then HTTP group).
const List<int> kAllPorts = <int>[
  443, 2053, 2083, 2087, 2096, 8443, // TLS
  80, 2052, 2082, 2086, 2095, 8080, // HTTP
];

/// The SNI presented during the deep-test TLS handshake (Nova Worker host).
const String kVlessSni = 'nova2.altramax083.workers.dev';
