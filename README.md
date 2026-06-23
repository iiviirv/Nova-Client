<div align="center">

<img src="assets/brand/nova-logo-gradient.svg" width="84" alt="Nova" />

# Nova Client

**An optimised, Nova-branded proxy client — a streamlined [Karing](https://github.com/KaringX/karing) fork — with the [Nova Radar](https://github.com/IRNova/NovaRadar) Cloudflare clean‑IP scanner built right in.**

Built in Flutter · dark‑first · bilingual (English + فارسی) · follows the [Nova Proxy](https://github.com/IRNova/Nova-Proxy) design language.

</div>

---

## What this is

Nova Client brings two Nova tools into a single cross‑platform app:

1. **A proxy client** in the spirit of Karing (a sing‑box GUI) — connect, manage
   profiles & subscriptions, and control routing — re‑skinned and slimmed down
   to the Nova Proxy visual language.
2. **Nova Radar** — the Cloudflare clean‑IP scanner (originally a Go + Wails
   desktop app) **ported to Dart** and consolidated in as a first‑class tab.

This milestone delivers the **design system**, the **app shell**, and a
**fully functional Radar**. The proxy data path (the modified sing‑box core)
is wired behind a clean integration boundary — see
[Architecture](#architecture).

## Status at a glance

| Area | State |
|------|-------|
| Nova design system (colors, gradient, type, radii) | ✅ Ported from `tokens.css` |
| Brand mark (the neon “N”), gradient, badges | ✅ Drawn from the brand SVG |
| App shell + responsive navigation (rail / bottom bar) | ✅ |
| Bilingual UI (English + فارسی, RTL) | ✅ |
| Dashboard (connect orb, live traffic, active profile) | ✅ UI · drives the proxy controller |
| Profiles & subscriptions (add / select / persist) | ✅ |
| Routing controls (mode + rule toggles) | ✅ UI |
| **Nova Radar scanner** | ✅ **Functional** (source fetch → IP gen → two‑phase TCP+TLS verify → latency sort → live progress → export) |
| sing‑box core (native VPN data path) | 🔌 Integration boundary (next milestone) |

## Design language

The whole UI is driven by the Nova Proxy design tokens, ported 1:1 from
`irnova-site/design-system/tokens.css` (kept here at
[`docs/nova-design-tokens.css`](docs/nova-design-tokens.css) for provenance):

- **Signature gradient** `linear-gradient(120deg, #22d3ee → #818cf8 → #a855f7)` —
  buttons, the logo, gradient text, progress, the connect orb.
- **Dark‑first** surfaces (`#05060a` page, translucent `surface` cards, hairline
  borders) with an opt‑in light theme.
- **Accents** cyan `#22d3ee` / violet `#a855f7` / indigo `#818cf8`.
- **Radii** 16 (cards) / 10 (inputs) / pill, and the accent elevation shadow.
- **Type** Inter (Latin) + Vazirmatn (Farsi), with the fluid weight/tracking
  scale.

These live in [`lib/src/theme/`](lib/src/theme) and are exposed to every widget
via a `ThemeExtension` (`context.nova.cyan`, …).

## Architecture

```
lib/
├── main.dart                     # entry — builds controllers, hydrates prefs
└── src/
    ├── app.dart                  # MaterialApp, theme/locale, NovaScope
    ├── theme/                    # design tokens → ThemeData (the design system)
    ├── l10n/                     # bilingual strings (en/fa) + delegate
    ├── widgets/                  # NovaLogo, NovaButton, NovaCard, app shell, …
    ├── core/
    │   ├── proxy/                # ProxyController boundary
    │   │   ├── proxy_controller.dart        # abstract: state + traffic
    │   │   ├── mock_proxy_controller.dart   # simulated, drives the UI today
    │   │   └── singbox_proxy_controller.dart# real core (MethodChannel contract)
    │   ├── models/               # ProxyProfile
    │   └── util/                 # formatting helpers
    └── features/
        ├── dashboard/            # connect screen
        ├── profiles/             # profiles & subscriptions
        ├── radar/                # ★ Nova Radar (ported scanner)
        │   ├── models.dart       # IpSource / ScanResult / ScanStats
        │   ├── sources.dart      # source fetch, CIDR math, random IP gen
        │   ├── scanner.dart      # two-phase TCP + TLS verification
        │   └── radar_controller.dart
        ├── routing/              # routing mode + rules
        └── settings/             # theme, language, links
```

**The sing‑box boundary.** The UI never talks to the native core directly — it
talks to a `ProxyController`. Today that's `MockProxyController` (a faithful
connection + traffic simulation) so the dashboard works end‑to‑end. The real
[`SingboxProxyController`](lib/src/core/proxy/singbox_proxy_controller.dart)
documents the `MethodChannel`/`EventChannel` contract each platform host
(Android `VpnService`, iOS/macOS Network Extension, desktop TUN helper) must
implement. Switching over is a one‑line change in `main.dart`.

## Nova Radar — what was ported

The Go backend (`scanner.go` / `sources.go`) was reimplemented in pure Dart
using `dart:io` sockets, preserving the original algorithm:

1. Fetch the enabled IP **sources** in parallel (9 sources: Cloudflare official,
   ASN ranges, CM list, reverse‑proxy IPs, resolved domains), with the built‑in
   Cloudflare ranges as fallback.
2. Generate up to 512 random candidate IPs spread across the CIDRs.
3. **Phase 1 — quick scan:** bounded‑concurrency TCP connect to each `ip:port`.
4. **Phase 2 — deep test:** a real **TLS handshake** (with the Nova Worker SNI)
   on TLS ports, or a TCP read probe on HTTP ports — 3× per candidate, keep
   those passing ≥2.
5. Sort fastest‑first, stream results live, and export as `ip:port#Nova-XXXXX`.

## Build & run

> This repo was authored in an environment without the Flutter SDK, so it is
> verified by CI (`flutter analyze` + `flutter test`) rather than locally. To
> run it you need [Flutter](https://docs.flutter.dev/get-started/install)
> (stable, ≥ 3.19).

```bash
flutter pub get
flutter run            # pick a device/desktop target
flutter test           # unit + widget tests
flutter analyze
```

Platform folders (`android/`, `ios/`, …) are generated with
`flutter create . --org online.novaproxy` on first checkout (kept out of the
repo to stay lean).

## Roadmap

- [ ] Native sing‑box core + per‑platform VPN service behind `SingboxProxyController`.
- [ ] Subscription parsing & node health‑check / ping.
- [ ] One‑click “use this IP” — feed a Radar result straight into the active profile.
- [ ] iCloud / WebDAV profile sync (Karing parity).

## Credits

- [Karing](https://github.com/KaringX/karing) — the sing‑box GUI this client is modelled on.
- [Nova Radar](https://github.com/IRNova/NovaRadar) — the scanner consolidated here.
- [Nova Proxy](https://github.com/IRNova/Nova-Proxy) & [novaproxy.online](https://novaproxy.online) — the product and design language.

<div align="center">
  <a href="https://novaproxy.online/">Website</a> ·
  <a href="https://t.me/irnova_proxy">Telegram</a> ·
  <a href="https://github.com/IRNova">GitHub</a>
</div>
