# Adding an Xray core to Nova Client — cost and plan

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
