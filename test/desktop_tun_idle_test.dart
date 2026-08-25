import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The full-device tunnel must not leave anything spinning on macOS or Linux.
///
/// A user on a 2015 MacBook Pro reported osascript at 10-12% CPU for the whole
/// session, the CPU pinned at 3GHz and the machine 20C hotter. Measuring showed
/// the old `while ... sleep 1` watcher was NOT the cost: osascript burns about
/// 5% of a core just staying alive while `do shell script` waits, whatever the
/// command is. So the launch is detached (osascript exits at once) and the
/// waiter blocks on a FIFO rather than polling.
///
/// Both properties live in the shape of the command, so the shape is what this
/// guards. It is a source check because the real thing needs a root password
/// and a TUN device, and neither belongs in a unit test.
void main() {
  final String source =
      File('lib/src/core/proxy/desktop_proxy_controller.dart')
          .readAsStringSync();

  /// The macOS/Linux branch: from the comment that introduces it to the end of
  /// the method that builds it.
  String unixBranch() {
    final int start = source.indexOf('// macOS / Linux: run via an admin');
    expect(start, greaterThan(0), reason: 'the elevated launch moved');
    final int end = source.indexOf('Future<void> _makeFifo', start);
    expect(end, greaterThan(start));
    return source.substring(start, end);
  }

  /// The same branch with `//` comments stripped, so prose describing the old
  /// bug does not read as the bug.
  String unixBranchCode() => unixBranch()
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('the elevated shell blocks on the control FIFO', () {
    expect(unixBranchCode(), contains('cat '),
        reason: 'read(2) on a FIFO costs nothing while it waits');
  });

  test('the launch is detached so osascript exits immediately', () {
    // This is the fix for the reported 5%, not the FIFO. `do shell script`
    // waits for the command AND for its descriptors to close, so both the
    // background & and the redirections are load-bearing.
    final String branch = unixBranchCode();
    // The work lives in a script file now (see the note in the source): the
    // inline form had to carry the core's environment and a path containing a
    // space through four layers of quoting, and when that broke it broke
    // silently. What still matters here is that the launch is detached.
    expect(branch, contains('nohup /bin/sh'));
    expect(branch, contains('> /dev/null 2>&1 &'));
  });

  test('it never sleeps in a loop', () {
    final String branch = unixBranchCode();
    expect(branch, isNot(contains('while ')),
        reason: 'any spin here keeps the CPU out of its idle states');
    // The waiting is still done by the blocking read above, which is the point.
    // A `sleep` on the teardown path is a different thing from a poll: it runs
    // once, after the tunnel is already coming down, to give the core a moment
    // to honour a TERM before it is forced. Guard the shape, not the word, so
    // this keeps catching a reintroduced poll without banning a single wait.
    final int sleeps = 'sleep '.allMatches(branch).length;
    expect(sleeps, lessThanOrEqualTo(1),
        reason: 'more than one sleep here means something is polling again');
  });

  test('a restarted launchd job does not dial back out', () {
    // launchd owns the job once it is submitted and may start it again after it
    // exits. Without this guard that turns every disconnect into a reconnect:
    // the core dies, the script ends, the job comes back and dials out, and the
    // user sees a Disconnect button that does nothing and a tunnel that
    // survives quitting Nova.
    expect(unixBranchCode(), contains(r"[ -f ${_shq(flag.path)} ] || exit 0"));
  });

  test('the tunnel is forced down if it ignores the first signal', () {
    final String branch = unixBranchCode();
    expect(branch, contains(r'kill -9 \$SB'),
        reason: '"disconnected" on screen has to mean the tunnel is down');
  });

  test('the FIFO is opened read-write, which never blocks', () {
    // Opening a FIFO write-only blocks until a reader appears, and the reader
    // here only exists after the user has typed their admin password. O_RDWR
    // (FileMode.write) returns at once.
    expect(source, contains('_tunCtl = await File(ctl.path).open(mode: FileMode.write)'));
  });

  test('closing the handle is what stops the tunnel', () {
    // And because the kernel closes it when the app dies, a crash tears the
    // root core down too. The old flag file could not do that.
    expect(source, contains('await ctl?.close()'));
  });

  test('the live pollers stop when no window is on screen', () {
    // A once-a-second Clash API call for numbers nobody is looking at is the
    // same class of problem, and it matters more now that closing the window
    // leaves Nova running in the menu bar.
    expect(source, contains('if (!_visible) return;'));
    expect(source, contains('AppLifecycleListener'));
  });

  test('macOS hands the elevated job to launchd, not to a background shell', () {
    // The bug this exists to stop coming back: a command backgrounded off
    // `do shell script ... with administrator privileges` is reaped by the
    // privileged trampoline before it can run. It works unelevated, which is why
    // it survived so long, and when it fails it leaves nothing behind at all,
    // not even an empty log. launchd is parented to PID 1 and cannot be reaped.
    expect(source, contains('launchctl submit'));
    expect(source, contains('with administrator privileges'));
  });

  test('the stale launchd job is cleared before submitting', () {
    // `do shell script` fails the whole command on a non-zero exit, so the
    // remove must not be the last thing to run and must swallow its own failure.
    expect(source, contains('launchctl remove'));
    expect(source, contains(r'launchctl remove $_tunJobLabel 2>/dev/null; '));
  });
}
