import '../../core/models/proxy_profile.dart';
import '../../core/proxy/aether/aether_options.dart';

/// What a new Aether config is called before the user renames it.
///
/// The protocol's own name, numbered when that name is already on the list, so
/// a second gool config arrives as "Gool 2" rather than a second row called
/// "Aether" that nobody can tell apart from the first.
///
/// Not localised on purpose: these are protocol names, and a profile called
/// "WireGuard" should read the same whichever language the app is in.
String aetherAutoName(
  AetherMode mode,
  List<ProxyProfile> profiles, {
  /// The config being edited, which does not count as a clash with itself.
  String? excludeId,
}) {
  final String base = switch (mode) {
    AetherMode.masque => 'MASQUE',
    AetherMode.wg => 'WireGuard',
    AetherMode.gool => 'Gool',
  };
  final Set<String> taken = <String>{
    for (final ProxyProfile p in profiles)
      if (p.id != excludeId) p.name.trim().toLowerCase(),
  };
  if (!taken.contains(base.toLowerCase())) return base;
  // Terminates because the set is finite: some number is always free.
  int n = 2;
  while (taken.contains('$base $n'.toLowerCase())) {
    n++;
  }
  return '$base $n';
}
