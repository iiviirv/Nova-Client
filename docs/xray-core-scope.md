# Adding an Xray core to Nova Client — cost and plan

## Phase-1 spike RESULT (2026-08-16): feasible ✅

Proven end to end on this machine:

- **Xray builds for Android via gomobile.** `tool/core/xray/novaxray` is a tiny
  wrapper (`Start(json)/Stop()/Version()`) around `xray-core v1.260327.0` with
  `distro/all` imported. `tool/core/build-xray.sh` gomobile-binds it to a 20 MB
  `libxray.aar` (arm64 built in ~18s); the AAR exports
  `online.novaproxy.xray.novaxray.Novaxray.start/stop/version`.
- **The xhttp transport is compiled in and a config starts the core**
  (`tool/core/xray/novaxray/xray_test.go`).
- **The client can translate an xhttp node to Xray JSON.**
  `lib/src/core/proxy/xray/xray_config.dart` turns a VLESS-over-xhttp node into a
  minimal Xray config (local socks inbound + xhttp outbound), and the **real Xray
  core accepted and started the client-generated config** (verified by feeding the
  Dart output into the Go wrapper). `test/xray_config_spike_test.dart` covers the
  translation. Also fixed: the share-link parser now captures `path` for xhttp.

So the core feasibility question — *can Nova build Xray for Android and run a
client-generated xhttp config through it* — is **yes**. None of this is wired into
the shipped app yet.

## Phase-2 progress + the blocker (2026-08-16)

Built and tested, all behind `kXrayXhttpEnabled = false` (dormant, app unchanged):

- **The two-core data path is designed and both halves validate.** sing-box owns
  the TUN and bridges it to a local SOCKS that Xray serves; Xray does the xhttp.
  `SingboxConfig.buildXraySocksBridge` (TUN -> SOCKS at 127.0.0.1:port) is
  accepted by the real sing-box core; `XrayConfig` (socks inbound + xhttp
  outbound) is accepted by the real Xray core.
- **Socket protection is solved.** The wrapper gained `SetProtector` +
  `internet.RegisterDialerController`, so Xray's outbound dials get
  `VpnService.protect` and don't loop back through the TUN. The AAR exports
  `setProtector(Protector{ protect(fd: Long) })`.
- **The controller + Android host are wired** (EXTRA_XRAY_CONFIG, start Xray
  before libbox, stop on cleanup) as a skeleton.

**BLOCKER found: two gomobile AARs cannot coexist.** libbox (sagernet's gomobile
fork) and libxray (upstream gomobile) each ship the `go/*` runtime support
classes, and the APK build fails `CheckDuplicates` on them; the two Go runtimes
also can't share one `go.Seq`. The fix is the standard one (NekoBox/Karing
libcore): **build sing-box AND xray-core into a SINGLE gomobile module** — one
`.aar`, one `go.Seq`, one runtime. So Phase-3 is a build-system task: add
`novaxray` (and xray-core) into the libbox build (sagernet's `build_libbox`, same
gomobile fork) and expose it from there, then flip `kXrayXhttpEnabled` and
uncomment the native calls (already in place). Nothing else in the path changes.

### What Phase-2 still needs (unchanged from below)
1. A **tun2socks bridge** from the VpnService TUN to Xray's local socks inbound
   (Xray has no TUN inbound). This is the missing data path.
2. A **Kotlin bridge** in NovaVpnService to call `Novaxray.start/stop`, and
   **core-per-node routing** (xhttp -> Xray, everything else -> sing-box).
3. An **Xray stats/observatory** equivalent for the coreHealth pings / logs /
   traffic that currently read libbox.
4. **Desktop binaries** and the **iOS binding + ~50 MB memory** work.
5. **End-to-end test against a real xhttp server** (the spike proves start/accept,
   not a live tunnel — no xhttp server was available).

---

# (Original scope) Adding an Xray core to Nova Client — cost and plan

Scoping for feedback item #5 (xhttp / SplitHTTP configs) and, adjacent, #6
(mieru). Nova Client today ships a single data core: a patched **sing-box**
(AmneziaWG + nova_fragment), bound natively per platform. xhttp is an
**Xray-only** transport (sing-box has no XHTTP outbound), so those configs cannot
connect no matter what we do in Dart. Supporting them means shipping a **second
core**.

## What "add Xray" actually is

1. **A second native binding per platform.** Xray-core (Go) has to be built the
   same way libbox is:
   - Android + iOS: `gomobile bind` of a small wrapper around
     `github.com/xtls/xray-core` (an `.aar` and an `.xcframework`), like
     libbox/Novacore today. Each is 25-60 MB.
   - Windows + macOS + Linux desktop: an `xray` binary per OS/arch, invoked and
     managed like the desktop sing-box process.
   This roughly **doubles the core build surface** (8 more build targets) and the
   app download size (**+25-40 MB per platform**).

2. **Config translation.** Nova speaks sing-box JSON everywhere (routing, DNS,
   rule-sets, the urltest pool, nova_fragment, the bypass). Xray uses a different
   JSON schema (inbounds/outbounds/routing/DNS all shaped differently). We would
   need an `XrayConfig` builder that reproduces, in Xray's schema, what
   `SingboxConfig` does: the TUN inbound, the auto-select (Xray `balancer` +
   `observatory` instead of sing-box `urltest`), routing rules, DNS, and the
   per-node fragment/bypass. This is the largest single piece.

3. **Routing between the two cores.** Only nodes whose transport is Xray-only
   (xhttp today) go to Xray; everything else stays on sing-box. The client has to
   pick the core per profile (or per node), run the right one, and keep the group
   /health/log/traffic command surfaces working for BOTH (the coreHealth pings,
   the "Connected via" line, Logs, the speed meter all currently read libbox).

4. **The command surface.** Everything built this month (live pings via
   `CommandGroup`, the reachability probe, Logs via `CommandLog`, traffic via
   `CommandStatus`) is libbox-specific. Xray exposes its stats/observatory over a
   gRPC API instead, so each of those features needs an Xray equivalent or a
   graceful "not available on this core" state.

5. **iOS memory.** The Network Extension's ~50 MB cap already forces the lean
   config. Running Xray there (another Go runtime + GC) is the real risk; it may
   only be viable on Android/desktop first, with iOS xhttp deferred.

## Effort

- **Phase 1 (spike, ~1 session):** gomobile-bind Xray for Android, a minimal
  `XrayConfig` for a single xhttp node, run it as a second core on Android only,
  prove an xhttp config connects. No auto-select, no routing polish, no iOS.
- **Phase 2:** config translation to parity (routing/DNS/balancer), desktop
  binaries, the command surface (stats/observatory), core-per-node selection.
- **Phase 3:** iOS binding + the memory work, or a decision to keep xhttp
  Android/desktop-only.

Realistically **several focused sessions**, and it grows the app materially.
This is the biggest single item in the backlog.

## Recommendation

xhttp is not yet common in Nova subscriptions. Unless a lot of users have
xhttp-only configs, the cost/benefit favors **waiting**: keep emitting the honest
"this transport needs the Xray core" skip note (already done), and revisit if
xhttp adoption grows. If we do proceed, do **Phase 1 as a spike first** so we
learn the real integration cost on one platform before committing to all four.

## #6 mieru

Same shape, worse: mieru is neither a sing-box nor an Xray outbound, so it needs
its own client (the `mieru` Go client, which Nova Server already runs as a
daemon) bound natively, or a mieru outbound written for one of the cores. Treat
it as its own effort after (or independently of) Xray; it does not come "for
free" with Xray.
