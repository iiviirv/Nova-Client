<div align="center">

<img src="assets/brand/nova-logo-gradient.svg" width="84" alt="Nova" />

# Nova Client

**Fast, free, unrestricted internet, on every device.**

A single Flutter codebase that runs Nova on **iOS, Android, macOS, Windows and Linux**, powered by the [sing-box](https://github.com/SagerNet/sing-box) core, with a one-tap connect, your own free Cloudflare panel, and a built-in clean-IP scanner.

Dark-first · bilingual (English + فارسی, RTL) · follows the [Nova Proxy](https://github.com/IRNova/Nova-Proxy) design language.

</div>

---

## Platform support

One codebase, one UI, with the sing-box data path bound natively per platform.

| Platform | Tunnel | Status | How to get it |
|----------|--------|--------|---------------|
| **iOS** | Network Extension (Packet Tunnel) | ✅ Builds, signs, runs on device + **TestFlight** | TestFlight invite, or build, see [`ios/IOS_BUILD.md`](ios/IOS_BUILD.md) |
| **macOS** | bundled sing-box + system proxy | ✅ Working (verified) | `flutter build macos` |
| **Windows** | bundled sing-box + WinINET proxy (no admin) | ✅ Buildable | see [`WINDOWS_BUILD.md`](WINDOWS_BUILD.md) |
| **Linux** | bundled sing-box + proxy | ⚠️ Builds; desktop core runs, system-proxy WIP | `flutter build linux` |
| **Android** | `VpnService` + libbox | ✅ Buildable here | `flutter build apk` (the mature production Android app is the native build at [iiviirv/nova-app](https://github.com/iiviirv/nova-app)) |

On **desktop** the core is the bundled `sing-box` process driven from pure Dart; on **iOS** it's a Network Extension; on **Android** it's the `VpnService`. The whole UI and all the Cloudflare / Radar logic are shared.

## Features

- **One-tap connect** with live status, country, IP, ping and traffic.
- **Connect Cloudflare**: sign in (PKCE OAuth), see your Workers + KV + D1 counts, **deploy your own free panel** (live timer, duplicate-name guard, timeout, password setup), delete workers.
- **Import from a panel**: pull a worker's configs into the app.
- **Servers**: subscriptions and single links (vless / vmess / trojan / ss / base64 / Clash), ping-sorted with country flags.
- **Nova Radar**: a Cloudflare clean-IP scanner (all TLS ports, configurable count, optional country target, strict `ip:port#name` output, one-tap push to your panel).
- **First-run onboarding**: pick a language, then deploy / import / add a config.
- **Routing** modes (rule / global / direct) with Iran + ad rule-sets, and a dark-first, fully bilingual UI.

## Install / build per platform

You need [Flutter](https://docs.flutter.dev/get-started/install) (stable, ≥ 3.27) and the toolchain for your target.

```bash
git clone -b claude/macos-desktop-core https://github.com/iiviirv/Nova-Client.git
cd Nova-Client && flutter pub get
```

- **iOS**: open `ios/Runner.xcworkspace` in Xcode, then `flutter build ios` (signing + the NetworkExtension are described in [`ios/IOS_BUILD.md`](ios/IOS_BUILD.md)). Easiest for testers: a TestFlight invite.
- **macOS**: `flutter build macos` (or `flutter run -d macos`).
- **Windows**: see the step-by-step [`WINDOWS_BUILD.md`](WINDOWS_BUILD.md) (needs Visual Studio with the Desktop C++ workload).
- **Android**: `flutter build apk`.

The bundled sing-box core binaries and how they're built/managed are documented in [`docs/DESKTOP.md`](docs/DESKTOP.md).

## Architecture

```
lib/src/
├── app.dart                       # MaterialApp, theme/locale, onboarding gate, NovaScope
├── theme/  l10n/  widgets/        # design system, bilingual strings, shared widgets
├── core/proxy/
│   ├── proxy_controller.dart      # the UI<->core boundary (state + traffic)
│   ├── desktop_proxy_controller.dart   # macOS/Windows/Linux: runs bundled sing-box from Dart
│   ├── singbox_proxy_controller.dart   # Android + iOS: MethodChannel to the native host
│   └── singbox/                   # share-link parsing + sing-box config builder
└── features/
    ├── dashboard/ profiles/ routing/ settings/
    ├── cloudflare/                # OAuth + Deploy + Panel clients, hub + deploy screens
    ├── onboarding/                # first-run language + how-to-start
    └── radar/                     # the clean-IP scanner
```

Native hosts implement the same `nova.proxy/control` channel:
- **Android**: `android/.../NovaVpnService.kt` (VpnService + libbox).
- **iOS**: `ios/NovaTunnel/PacketTunnelProvider.swift` + `ios/Runner/NovaProxyHost.swift` (NetworkExtension; core is `Libbox.xcframework`).
- **Desktop**: no native host needed, the Dart controller runs the bundled `sing-box` and points the OS proxy at it.

## Credits

Built on [sing-box](https://github.com/SagerNet/sing-box) (GPL-3.0) by the SagerNet team. UI modelled on [Karing](https://github.com/KaringX/karing). Part of [Nova Proxy](https://github.com/IRNova/Nova-Proxy).

---
<div dir="rtl">

## نوا کلاینت

**اینترنت سریع، رایگان و بدون محدودیت، روی همه‌ی دستگاه‌ها.**

یک کدِ واحد با فلاتر که نوا را روی **iOS، اندروید، مک، ویندوز و لینوکس** اجرا می‌کند؛ با هسته‌ی sing-box، اتصال یک‌لمسی، پنل رایگان اختصاصی روی Cloudflare و اسکنر آی‌پی تمیز.

- **iOS**: با Network Extension؛ روی دستگاه و **TestFlight** اجرا می‌شود.
- **مک**: کار می‌کند (تأییدشده) با `flutter build macos`.
- **ویندوز**: قابل ساخت؛ راهنما در `WINDOWS_BUILD.md` (بدون نیاز به دسترسی ادمین).
- **اندروید**: قابل ساخت؛ نسخه‌ی اصلی اندروید به‌صورت native در iiviirv/nova-app منتشر شده است.

امکانات: اتصال یک‌لمسی، اتصال به Cloudflare و ساخت/وارد کردن پنل، اسکنر رادار، آنبوردینگ، و رابط کاملاً دوزبانه (انگلیسی + فارسی).

ساخته‌شده بر پایه‌ی sing-box (مجوز GPL-3.0).

</div>

<div align="center">
  <a href="https://novaproxy.online/">Website</a> ·
  <a href="https://t.me/irnova_proxy">Telegram</a> ·
  <a href="https://github.com/IRNova">GitHub</a>
</div>
