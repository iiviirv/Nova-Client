import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_client/src/features/profiles/profiles_controller.dart';

/// The server list is pushed as its own route from Subscriptions, so a Connect
/// there has to do two things: leave that route, and move the shell to the
/// dashboard. Popping is the caller's business. This is the second half.
///
/// A counter rather than a flag, because two Connects in a row are two events
/// and a flag would swallow the second: the user would tap, land on the
/// dashboard, go back, tap again, and stay put.
void main() {
  test('asking twice is heard twice', () {
    final ProfilesController c = ProfilesController();
    int heard = 0;
    void onHome() => heard++;
    c.homeRequests.addListener(onHome);
    addTearDown(() => c.homeRequests.removeListener(onHome));

    c.goHome();
    expect(heard, 1);
    c.goHome();
    expect(heard, 2, reason: 'a flag would have swallowed the second request');
  });

  test('nobody is taken home without asking', () {
    final ProfilesController c = ProfilesController();
    int heard = 0;
    void onHome() => heard++;
    c.homeRequests.addListener(onHome);
    addTearDown(() => c.homeRequests.removeListener(onHome));

    c.selectTab(true);
    c.selectTab(false);
    expect(heard, 0,
        reason: 'switching the Servers sub-tab is not a request to leave it');
  });

  test('the counter starts where a listener can tell it has not fired', () {
    expect(ProfilesController().homeRequests.value, 0);
  });

  test('the shell listens for it, and lets go', () {
    // Structural rather than a full shell pump, which needs every controller
    // and a plugin-backed store. What this catches is the listener being
    // dropped, which would leave the button connecting and going nowhere, and
    // a listener never removed, which outlives the shell.
    final String shell =
        File('lib/src/widgets/nova_app_shell.dart').readAsStringSync();
    expect(shell, contains('homeRequests.addListener'));

    // Scoped to dispose(), not the file: the removal also appears in
    // didChangeDependencies when the controller is swapped, so looking anywhere
    // would pass while the one that prevents the leak was gone.
    int depth = 0;
    final int at = shell.indexOf('void dispose() {');
    expect(at, isNot(-1), reason: 'dispose moved or was renamed');
    int i = shell.indexOf('{', at);
    final int start = i;
    for (; i < shell.length; i++) {
      if (shell[i] == '{') depth++;
      if (shell[i] == '}') {
        depth--;
        if (depth == 0) break;
      }
    }
    expect(shell.substring(start, i), contains('homeRequests.removeListener'),
        reason: 'a listener left attached outlives the shell and fires into a '
            'dead State');
  });
}
