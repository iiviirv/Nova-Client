import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/geo/node_geo_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Node flags: the server's name is never replaced; the flag comes from the
/// best thing known, persists, and an exit observed while connected beats any
/// address lookup and is never overwritten by one.
void main() {
  test('exit beats guess, persists, survives reload', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final NodeGeoStore s = NodeGeoStore.instance;
    s.attachPrefs(prefs);

    s.setGuess('k1', const NodeGeo(frontedBy: 'Cloudflare'));
    expect(s['k1']!.frontedBy, 'Cloudflare');
    expect(s['k1']!.countryCode, '');

    s.learnExit('k1', 'DE', countryName: 'Germany');
    expect(s['k1']!.countryCode, 'DE');
    expect(s['k1']!.fromExit, isTrue);

    // A later lookup (the address still looks like a CDN edge) must not undo it.
    s.setGuess('k1', const NodeGeo(frontedBy: 'Cloudflare'));
    expect(s['k1']!.countryCode, 'DE');

    // Persisted and reloaded.
    expect(prefs.getString('nova.nodegeo.v1'), contains('"DE"'));
    s.attachPrefs(prefs);
    expect(s['k1']!.countryCode, 'DE');
    expect(s['k1']!.fromExit, isTrue);
  });
}
