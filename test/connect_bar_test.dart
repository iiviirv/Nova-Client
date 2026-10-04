import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Connect button on the pushed server list, and the one place it must not
/// appear.
///
/// Structural, and that is a compromise worth naming: the behaviour was proved
/// with a widget harness while it was written, and the harness was deleted with
/// it. A guard tested once and then left uncovered is the same as untested the
/// next time someone edits around it, so what survives here is the check that
/// the guard still exists and still comes first.
void main() {
  final String src =
      File('lib/src/features/servers/node_list_screen.dart').readAsStringSync();

  test('the embedded list gets no button of its own', () {
    expect(src, contains('if (widget.embedded) return body;'),
        reason: 'the dashboard already has the big connect button directly '
            'below this list, so a second one there is noise');
  });

  test('the guard runs before the bar is built, not after', () {
    final int guard = src.indexOf('if (widget.embedded) return body;');
    final int bar = src.indexOf('_ConnectBar');
    expect(guard, isNot(-1));
    expect(bar, isNot(-1));
    expect(guard, lessThan(bar),
        reason: 'building the bar and then discarding it would still run its '
            'listeners against the dashboard copy of this list');
  });

  test('tapping it both leaves the route and asks for the dashboard', () {
    // Two halves, and either one alone is a bug: popping without the request
    // drops the user on whatever tab they were on, and the request without the
    // pop leaves the pushed route sitting on top of the dashboard.
    expect(src, contains('popUntil'));
    expect(src, contains('goHome()'));
  });

  test('the list reserves room so the button cannot cover the last server', () {
    expect(src, contains('_ConnectBar.reserveFor'),
        reason: 'a floating button over the final row makes it unreachable, '
            'which is worse than having no button');
  });
}
