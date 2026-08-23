import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/core/proxy/proxy_controller.dart';

/// Switching server is a disconnect followed by a connect. Both halves used to
/// destroy the lightning test: the disconnect cleared the board outright, and
/// the connect replaced whatever survived with the tunnel's own live pings. A
/// two-minute sweep became a handful of numbers, and the rest of the list went
/// blank until the user left the screen and came back.
void main() {
  const CoreNodeHealth measured = CoreNodeHealth(
    delayMsByKey: <String, int>{'a': 40, 'b': 120, 'c': 300},
    testedKeys: <String>{'a', 'b', 'c', 'd'},
  );

  test('a live reading never overwrites a measured one', () {
    const CoreNodeHealth live = CoreNodeHealth(
      delayMsByKey: <String, int>{'a': 900},
      testedKeys: <String>{'a'},
      selectedKey: 'a',
    );
    final CoreNodeHealth out = measured.withLive(live);
    expect(out.delayMsByKey['a'], 40,
        reason: 'the measured 40ms stands, not the tunnel 900ms');
    expect(out.delayMsByKey['b'], 120);
    expect(out.delayMsByKey['c'], 300);
  });

  test('a live reading fills in a server that was never measured', () {
    const CoreNodeHealth live = CoreNodeHealth(
      delayMsByKey: <String, int>{'z': 55},
      testedKeys: <String>{'z'},
      selectedKey: 'z',
    );
    final CoreNodeHealth out = measured.withLive(live);
    expect(out.delayMsByKey['z'], 55, reason: 'nothing to lose, so take it');
    expect(out.delayMsByKey.length, 4);
  });

  test('the selection always follows the tunnel', () {
    const CoreNodeHealth live =
        CoreNodeHealth(delayMsByKey: <String, int>{}, selectedKey: 'b');
    expect(measured.withLive(live).selectedKey, 'b',
        reason: 'the list still has to show which server is carrying traffic');
  });

  test('disconnecting drops the selection and keeps every reading', () {
    const CoreNodeHealth connected = CoreNodeHealth(
      delayMsByKey: <String, int>{'a': 40, 'b': 120},
      testedKeys: <String>{'a', 'b'},
      selectedKey: 'a',
    );
    final CoreNodeHealth after = connected.withoutSelection;
    expect(after.selectedKey, isNull);
    expect(after.delayMsByKey, <String, int>{'a': 40, 'b': 120});
    expect(after.testedKeys, <String>{'a', 'b'});
  });

  test('a full switch cycle leaves the board exactly as it was', () {
    // disconnect, then connect to a different server.
    final CoreNodeHealth afterSwitch = measured.withoutSelection.withLive(
      const CoreNodeHealth(
        delayMsByKey: <String, int>{'b': 777},
        testedKeys: <String>{'b'},
        selectedKey: 'b',
      ),
    );
    expect(afterSwitch.delayMsByKey, measured.delayMsByKey,
        reason: 'nothing the user measured may change on a switch');
    expect(afterSwitch.selectedKey, 'b');
  });
}
