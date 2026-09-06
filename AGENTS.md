# Working in this repo

Nova Client is the shipped Flutter client: Android, iOS, macOS, Windows and Linux
from one tree, with a sing-box based core in `ios/Frameworks/` and
`tool/core/build-*.sh`.

## Hard conventions (do not violate)

- **No AI attribution in git history.** The maintainer (`iiviirv`) is the sole
  author. Never put `Co-Authored-By: Claude`, `Claude-Session:`, "Generated with
  Claude", or any other AI credit in a commit message, PR body, release notes or
  docs. This has been scrubbed from history on other Nova repos twice, and a
  single trailer that lands and gets pushed puts an AI back on the GitHub
  contributor list. **First thing in a fresh clone, run
  `git config core.hooksPath .githooks`** so the tracked `commit-msg` hook strips
  these lines automatically. Do not disable that hook. Real human co-authors are
  fine; only AI attribution is forbidden.
- **No AI tells, no em dashes.** Never use `—` or `–`; rewrite with a comma, a
  colon, parentheses, or the word "to". No decorative middots `·`, no `~` for
  "about". Applies to code, comments, UI copy, commits and docs.
- **A test that has never failed has not been tested.** After writing a test,
  break the code it covers and watch it fail, then restore. This repo has already
  shipped a bug that survived because a test was written from the same assumption
  as the code.
- **Verify from the source of truth.** Check the thing the running system uses,
  not whatever answers first, and say which source you checked.

## Gotchas that have cost real time

- **Android builds need JDK 17.** The system Java here is a JRE with no `javac`,
  so set `JAVA_HOME=/opt/homebrew/opt/openjdk@17`.
- **`CleanIpStore` is a singleton that caches its `SharedPreferences` handle.**
  Without `resetForTests()` the first test's prefs are reused by every later one
  and saved settings are silently ignored. When a test fails, suspect pollution
  *and* a real bug: both have happened back to back in this file.
- **`Novacore.xcframework` is gitignored**, so a fresh clone has to rebuild it
  with `bash tool/core/build-combined-core-ios.sh` before an iOS build.
- **`swiftc -parse` accepts invented framework enum members.** Only a real build
  catches them.
- **The macOS core inherits the build machine's OS as its minimum.** Set
  `MACOSX_DEPLOYMENT_TARGET=12.0` or every Mac on an older release SIGKILLs it.

## Tests

`flutter test` runs the suite. Three failures are known, network-dependent, and
fail on a clean tree too: one in `nova_panel_test.dart` and two in
`subscription_connect_test.dart`. Confirm against a clean tree before blaming a
change for them.
