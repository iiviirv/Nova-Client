# Handoff: protect the free list from being read off a public URL

## The problem

Nova's free subscription is published at a world-readable URL
(`kFreeSubUrl`, `lib/src/core/models/proxy_profile.dart:293` →
`raw.githubusercontent.com/IRNova/Tools/refs/heads/main/sub.txt`).

One unauthenticated request returns **86 configs across 71 addresses**, including
bare Cloudflare IPs. A censor does not need the app, an account, or the panel: they
fetch the file and block every address in it. Free servers stop working in about
two days. Verified 2026-09-06.

The defence already exists in the app and was switched off. `CleanIpFronting.applySpread`
re-addresses the free list through Cloudflare addresses found on **this** network,
giving each server one of the best few at random and moving the published domain to
the TLS name so the server still sees the handshake it expects.

Why that beats the obvious alternative (publish `127.0.0.1`, let each user paste an
IP): it needs nothing from the user, it is per-network rather than one address that
is wrong for most people, and there is no single shared address to burn. It also
keeps "install it, press Connect" true, which is the whole point of the free list.

## Already done (branch `free-list-clean-ip-default`, commit `7205370`)

Do not redo these.

1. **`kBoostFreeListByDefault = true`** in `lib/src/core/cleanip/clean_ip_store.dart`.
   One switch, so it can be measured and reverted in one place. A saved user choice
   still wins in both directions.
2. **`CleanIpFinder` now fills the pool**, not just the single best address
   (`lib/src/core/cleanip/clean_ip_finder.dart`). Previously only the Radar *screen*
   ever called `recordPool`, so a user who never opened Radar had an empty
   `freshPool` and the re-addressing silently did nothing. This is what makes the
   default reach people.
3. **Fixed a real bug the new default exposed.** `CleanIpStore.load()` returned early
   when no best address was saved, skipping the reads below it. Invisible while the
   field defaulted to the same value the early return left it at; with the default
   flipped it would have silently turned re-addressing back ON for users who had
   deliberately turned it off. Settings must not depend on whether an unrelated key
   exists.
4. **`resetForTests()` seam** on `CleanIpStore`, because the singleton caches its
   `SharedPreferences` handle and without it the first test's prefs are reused by
   every later one. This cost an hour: a failing test looked like a code bug and was
   test pollution, and then a *second* failure that looked like pollution turned out
   to be the real bug in item 3. Suspect both, check both.
5. **`test/free_list_protection_test.dart`**, 5 tests, mutation-verified: they fail
   when the default is reverted and when the early return is restored.

6. **The connect path now reads the pool** (`applyAvailable` in
   `clean_ip_fronting.dart`, called from `_frontWithCleanIp` in both
   `singbox_proxy_controller.dart` and `desktop_proxy_controller.dart`). See
   "Item 1, done" below for what this did and did not turn out to be.

State: 525 tests pass. Three failures (`nova_panel_test`, `subscription_connect_test`)
are pre-existing and network-dependent; they fail on a clean tree too. Not released,
given the standing release hold.

## What remains

### Item 1, done. Read this before trusting the old description of it.

**The premise was half right, and the half that was wrong matters.**

The original note said a user who never taps refresh "never gets re-addressed
configs". That is not what the code did. `buildFreeProfile()` sets
`hardenTls: true`, and the connect path already called `_frontWithCleanIp` on
every connect for any profile with that flag. So those users *were* getting
re-addressed, from the moment a scan had run.

What they were getting was the weak version. `_frontWithCleanIp` read
`CleanIpFinder.current()`, a *single* stored address, and called
`CleanIpFronting.apply`, which gives that one address to every node. The pool
that the finder was taught to fill was read by nothing but the free-list screen.
So the fix in "already done" item 2 was, on the path that carries traffic, dead
code: written, stored, never read.

That single address is exactly what `applySpread`'s own comment warns about, "a
single point of failure and a single thing for a filter to notice: every device
that ran a scan ends up dialling the same IP for every server it has."

**The change:** `CleanIpFronting.applyAvailable(nodes, pool:, single:)` picks the
pool when there is one and falls back to the single address when there is not,
and both controllers call it. Spreading now happens on every connect, for every
`hardenTls` profile, not only when someone taps refresh.

**The `node_list_screen.dart:325` constraint is untouched.** No probing was
added. This reads addresses a scan already recorded; it starts nothing. The
screen's `_boostFreeListAddresses()` still has its one caller and can stay that
way, since it now only affects what the list *displays*.

Tests are in `test/free_list_protection_test.dart`. Three are mutation-verified
(ignore the pool, break the single-address fallback, revert a controller to
`apply`, each fails the matching test). The fourth, "leaves the list alone when
no scan has found anything", is a boundary assertion that no honest one-line
mutation can break; it is documentation, not a guard.

One of those tests reads the two controller source files and asserts the call is
present. That is deliberate. The bug this branch exists to fix was never a wrong
function, it was a right function nobody called, and every behavioural test here
passes just as happily with the connect path reverted. Wiring is the thing that
broke, so wiring is what is asserted.

### Open question this raised: the toggle does not reach the connect path

`boostFreeList` gates `_boostFreeListAddresses()` on the free-list screen.
`_frontWithCleanIp` is gated on `hardenTls` and has never consulted the toggle.
So a user who turns re-addressing OFF in Radar still gets fronted on connect,
before and after this change.

This was left alone on purpose: honouring the toggle there would *remove*
protection from anyone who has it off, which is a product decision, not a
cleanup. But the store's own doc comment says "The user can still turn it off in
Radar", and on the path that matters that is currently not true. Decide which of
the two should move, the comment or the gate.

### 1. First connect goes out unprotected

`CleanIpFinder.ensure()` (`clean_ip_finder.dart:104`) is fire-and-forget by design:
"the first connect goes out unfronted and the next one benefits". Called from
`singbox_proxy_controller.dart:1486` and `desktop_proxy_controller.dart:1087`, and
only when `fresh == null`.

Decide, with a measurement rather than a guess: is the first session on published
(likely-blocked) addresses acceptable, or should first connect wait a few seconds
for a scan? A scan is `kSampleSize = 128` addresses over ports 443/2053/8443 with a
45s budget, so measure the realistic time-to-first-address on a phone before
choosing. Do not block the connect path on a slow network.

### 2. Verify the Radar toggle reflects the new default

`radar_screen.dart:458` binds to `store.boostFreeList`. Confirm the switch shows ON
for a fresh install and that turning it off still sticks across a restart.

### 3. On-device verification

Emulator is not sufficient here: the whole point is which addresses are reachable
from a real network. Test on a real device, ideally on an Iranian connection through
a tester. Confirm the free list actually dials scanned IPs (check Settings → Logs
for "Kept N scanned addresses for the free list") and that connections succeed.

## Coordination note, do not skip

The published `sub.txt` still contains bare IPs. Sanitising it to domain-only removes
the oracle, but those domains get filtered too, so **domain-only is only safe once
this client change has shipped and is confirmed working in the field**. Doing it
first makes things worse. Order: ship the app change → confirm re-addressing works on
real networks → sanitise the published list.

## Test discipline

Break the code and watch the test fail before trusting it. Both mutations above were
run and both failed the tests. A test written from the same assumption as the bug
passes against broken code, and this file already contains one bug that hid for
exactly that reason.
