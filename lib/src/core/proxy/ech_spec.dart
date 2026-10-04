/// Where to get an ECH key from, in the form other clients already use.
///
/// `cloudflare-ech.com+udp://1.1.1.1` means: look up the HTTPS record of
/// `cloudflare-ech.com`, asking the resolver `udp://1.1.1.1`. Nova accepts the
/// same text so a setting that works elsewhere can be pasted in rather than
/// translated.
///
/// Both halves are optional. A bare domain keeps Nova's resolver, and a bare
/// resolver keeps the domain every Cloudflare zone publishes.
class EchSpec {
  const EchSpec({required this.domain, required this.resolver});

  /// The default: the name every Cloudflare zone publishes a key under, over
  /// DNS-over-HTTPS by address.
  ///
  /// DoH rather than the `udp://1.1.1.1` other clients default to, because UDP
  /// to Cloudflare is blocked on the networks this feature exists for, and a
  /// lookup those networks drop is not a lookup. By address so that resolving
  /// the resolver is not a prerequisite.
  static const EchSpec fallback = EchSpec(
    domain: 'cloudflare-ech.com',
    resolver: 'https://1.1.1.1/dns-query',
  );

  final String domain;

  /// `udp://host[:port]`, `tcp://host[:port]`, or an `https://` DoH endpoint.
  final String resolver;

  /// Parses the `domain+resolver` form. Returns the default for empty or
  /// unusable text rather than failing: this comes from a text field, and a
  /// typo should cost the typist their customisation, not their connection.
  static EchSpec parse(String? text) {
    final String t = (text ?? '').trim();
    if (t.isEmpty) return fallback;
    String domain = fallback.domain;
    String resolver = fallback.resolver;
    // Split on the first '+' that is not inside the scheme, so a resolver
    // containing one cannot be mistaken for the separator.
    final int plus = t.indexOf('+');
    final String left = plus < 0 ? t : t.substring(0, plus);
    final String right = plus < 0 ? '' : t.substring(plus + 1);
    for (final String part in <String>[left, right]) {
      final String p = part.trim();
      if (p.isEmpty) continue;
      if (_isResolver(p)) {
        resolver = p;
      } else if (_isDomain(p)) {
        domain = p;
      }
    }
    return EchSpec(domain: domain, resolver: resolver);
  }

  static bool _isResolver(String s) {
    final String l = s.toLowerCase();
    return l.startsWith('udp://') ||
        l.startsWith('tcp://') ||
        l.startsWith('https://');
  }

  static bool _isDomain(String s) =>
      s.contains('.') && !s.contains('/') && !s.contains(' ');

  /// The text form, so what is stored round-trips through the editor.
  String get text => '$domain+$resolver';

  bool get isDefault =>
      domain == fallback.domain && resolver == fallback.resolver;

  /// A key for caching, since a different spec is a different answer.
  String get cacheKey => '$domain|$resolver';

  @override
  bool operator ==(Object other) =>
      other is EchSpec && other.domain == domain && other.resolver == resolver;

  @override
  int get hashCode => Object.hash(domain, resolver);

  @override
  String toString() => text;
}
