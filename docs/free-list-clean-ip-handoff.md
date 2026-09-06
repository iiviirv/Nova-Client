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

State: 521 tests pass. Three failures (`nova_panel_test`, `subscription_connect_test`)
are pre-existing and network-dependent; they fail on a clean tree too. Not released,
given the standing release hold.

## What remains

### 1. The re-addressing only runs on manual refresh (the big one)

`_boostFreeListAddresses()` has exactly one caller: `_manualRefresh()` at
`lib/src/features/servers/node_list_screen.dart:351`, behind `if (profile.isBuiltIn)`.

So a user who never taps the refresh button never gets re-addressed configs, no
matter what the default says. **This is the change that actually delivers the
protection.** The others are prerequisites.

Needs re-addressing to run wherever the free list is loaded for use, not only when
the user asks. Note the deliberate design constraint recorded at
`node_list_screen.dart:325`: automatic testing was removed on purpose and "nothing
starts until this button". Re-addressing is not the same thing as latency testing,
but respect the intent, do not reintroduce background probing of every node.

### 2. First connect goes out unprotected

`CleanIpFinder.ensure()` (`clean_ip_finder.dart:104`) is fire-and-forget by design:
"the first connect goes out unfronted and the next one benefits". Called from
`singbox_proxy_controller.dart:1486` and `desktop_proxy_controller.dart:1087`, and
only when `fresh == null`.

Decide, with a measurement rather than a guess: is the first session on published
(likely-blocked) addresses acceptable, or should first connect wait a few seconds
for a scan? A scan is `kSampleSize = 128` addresses over ports 443/2053/8443 with a
45s budget, so measure the realistic time-to-first-address on a phone before
choosing. Do not block the connect path on a slow network.

### 3. Verify the Radar toggle reflects the new default

`radar_screen.dart:458` binds to `store.boostFreeList`. Confirm the switch shows ON
for a fresh install and that turning it off still sticks across a restart.

### 4. On-device verification

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
