import 'dart:convert';

/// How the tunnel's payload is encrypted. The ids are the engine's own and must
/// not be renumbered: they are what goes into `DATA_ENCRYPTION_METHOD`.
enum MasterDnsMethod {
  none(0, 'None'),
  xor(1, 'XOR'),
  chacha20(2, 'ChaCha20'),
  aes128(3, 'AES-128-GCM'),
  aes192(4, 'AES-192-GCM'),
  aes256(5, 'AES-256-GCM');

  const MasterDnsMethod(this.id, this.label);

  final int id;
  final String label;

  static MasterDnsMethod fromId(int? id) => MasterDnsMethod.values
      .firstWhere((MasterDnsMethod m) => m.id == id, orElse: () => xor);

  /// Accepts either the number or the name, because both appear in configs
  /// people paste: the engine writes numbers, other clients show names.
  static MasterDnsMethod parse(Object? v) {
    if (v is num) return fromId(v.toInt());
    final String s = '$v'.trim().toLowerCase().replaceAll('_', '-');
    final int? n = int.tryParse(s);
    if (n != null) return fromId(n);
    for (final MasterDnsMethod m in MasterDnsMethod.values) {
      if (m.label.toLowerCase() == s || m.name == s) return m;
    }
    return xor;
  }
}

/// A MasterDNS tunnel, as a user thinks of it.
///
/// Two things about the engine shape everything here, and neither is visible
/// from the configs people share.
///
/// Its JSON loader reads only the exact upper-case names (`DOMAINS`,
/// `ENCRYPTION_KEY`, `DATA_ENCRYPTION_METHOD`). The lower-case `domain`, `key`
/// and `method` that other clients show are silently ignored, so a config
/// passed through unchanged starts with no domain and no key.
///
/// And resolvers cannot be given in that JSON at all: the field is excluded
/// from decoding, and JSON mode clears the resolvers file path. A config with
/// resolvers in its JSON starts with none and never connects. They have to be
/// written to a file and handed over separately, which [resolversFile] is for.
class MasterDnsConfig {
  const MasterDnsConfig({
    required this.domains,
    required this.key,
    this.method = MasterDnsMethod.xor,
    this.resolvers = const <String>[],
    this.name = '',
  });

  final List<String> domains;
  final String key;
  final MasterDnsMethod method;
  final List<String> resolvers;
  final String name;

  /// What is missing before this can connect, or null when nothing is.
  String? get problem {
    if (domains.every((String d) => d.trim().isEmpty)) return 'no domain';
    if (method != MasterDnsMethod.none && key.trim().isEmpty) {
      return 'no encryption key';
    }
    if (resolvers.every((String r) => r.trim().isEmpty)) return 'no resolvers';
    return null;
  }

  /// The configuration the engine actually reads, with every name spelled the
  /// way its loader expects. The listen address is always loopback: this
  /// process is the only thing that should reach it, and sing-box forwards into
  /// it.
  String engineJson({required int port}) => jsonEncode(<String, dynamic>{
        'DOMAINS': <String>[
          for (final String d in domains)
            if (d.trim().isNotEmpty) d.trim(),
        ],
        'ENCRYPTION_KEY': key.trim(),
        'DATA_ENCRYPTION_METHOD': method.id,
        'PROTOCOL_TYPE': 'SOCKS5',
        'LISTEN_IP': '127.0.0.1',
        'LISTEN_PORT': port,
      });

  /// The engine's JSON, base64 encoded the way its `-json_base64` flag wants.
  /// Passed on the command line rather than written to disk, so the key is not
  /// left in a file.
  String engineJsonBase64({required int port}) =>
      base64.encode(utf8.encode(engineJson(port: port)));

  /// The resolvers file: one per line, which is the engine's own format.
  String get resolversFile => '${<String>[
        for (final String r in resolvers)
          if (r.trim().isNotEmpty) r.trim(),
      ].join('\n')}\n';

  /// The friendly form, the same shape other clients show, for the text editor
  /// and for sharing.
  Map<String, dynamic> toFriendlyJson() => <String, dynamic>{
        'domain': domains.length == 1 ? domains.first : domains,
        'key': key,
        'method': method.id,
        'resolvers': resolvers,
      };

  /// A shareable link. The engine defines no link format, so this one is
  /// Nova's: the friendly JSON, base64url encoded, with the name as a fragment.
  String toLink() {
    final String body = base64Url
        .encode(utf8.encode(jsonEncode(toFriendlyJson())))
        .replaceAll('=', '');
    final String frag = name.isEmpty ? '' : '#${Uri.encodeComponent(name)}';
    return 'masterdns://$body$frag';
  }

  static MasterDnsConfig? parseLink(String input) {
    final String s = input.trim();
    if (!s.toLowerCase().startsWith('masterdns://')) return null;
    String rest = s.substring('masterdns://'.length);
    String name = '';
    final int hash = rest.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }
    try {
      final String padded = rest.padRight((rest.length + 3) ~/ 4 * 4, '=');
      final String json = utf8.decode(base64Url.decode(padded));
      final MasterDnsConfig? c = parseText(json);
      if (c == null) return null;
      return MasterDnsConfig(
          domains: c.domains,
          key: c.key,
          method: c.method,
          resolvers: c.resolvers,
          name: name);
    } catch (_) {
      return null;
    }
  }

  /// Reads a config someone pasted, in any of the shapes that circulate: the
  /// friendly JSON other clients show, the engine's own upper-case JSON, or the
  /// engine's TOML. Returns null when it is none of those.
  static MasterDnsConfig? parseText(String input) {
    final String s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('{')) {
      try {
        final Object? decoded = jsonDecode(s);
        if (decoded is Map) return _fromMap(decoded.cast<String, dynamic>());
      } catch (_) {
        return null;
      }
      return null;
    }
    return _fromToml(s);
  }

  static MasterDnsConfig? _fromMap(Map<String, dynamic> m) {
    Object? pick(List<String> names) {
      for (final String n in names) {
        for (final MapEntry<String, dynamic> e in m.entries) {
          if (e.key.toLowerCase() == n.toLowerCase()) return e.value;
        }
      }
      return null;
    }

    final List<String> domains =
        _list(pick(<String>['DOMAINS', 'domain', 'domains']));
    final Object? key = pick(<String>['ENCRYPTION_KEY', 'key', 'encryption_key']);
    final Object? method =
        pick(<String>['DATA_ENCRYPTION_METHOD', 'method', 'encryption_method']);
    final List<String> resolvers = _list(pick(<String>['resolvers', 'RESOLVERS']));
    if (domains.isEmpty && key == null) return null;
    return MasterDnsConfig(
      domains: domains,
      key: key == null ? '' : '$key',
      method: method == null ? MasterDnsMethod.xor : MasterDnsMethod.parse(method),
      resolvers: resolvers,
    );
  }

  /// Just enough TOML for the fields that matter. The engine's sample config is
  /// TOML, so that is what people copy, and a full TOML parser for three keys
  /// is more than the job needs.
  static MasterDnsConfig? _fromToml(String s) {
    final Map<String, String> kv = <String, String>{};
    for (final String raw in const LineSplitter().convert(s)) {
      final String line = raw.split('#').first.trim();
      final int eq = line.indexOf('=');
      if (eq <= 0) continue;
      kv[line.substring(0, eq).trim().toUpperCase()] =
          line.substring(eq + 1).trim();
    }
    if (!kv.containsKey('DOMAINS') && !kv.containsKey('ENCRYPTION_KEY')) {
      return null;
    }
    String unquote(String? v) =>
        (v ?? '').replaceAll(RegExp(r'''^["']|["']$'''), '');
    final List<String> domains = RegExp(r'''["']([^"']+)["']''')
        .allMatches(kv['DOMAINS'] ?? '')
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    return MasterDnsConfig(
      domains: domains,
      key: unquote(kv['ENCRYPTION_KEY']),
      method: MasterDnsMethod.parse(kv['DATA_ENCRYPTION_METHOD'] ?? '1'),
    );
  }

  static List<String> _list(Object? v) {
    if (v == null) return const <String>[];
    if (v is List) {
      return <String>[
        for (final Object? e in v)
          if ('$e'.trim().isNotEmpty) '$e'.trim(),
      ];
    }
    return '$v'
        .split(RegExp(r'[\n,]'))
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }
}
