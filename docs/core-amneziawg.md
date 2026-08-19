# The Nova core: sing-box with AmneziaWG

Nova's Android core is **not** stock sing-box. This file is the record of what
it is built from, so the binary in `android/app/libs/libbox.aar` can be rebuilt
by anyone, and so nobody has to trust an AAR somebody produced once on a laptop.

**Two things this record does not claim, stated here so they are not lost
further down.** The core has never been tested against a Nova node: every tunnel
measured below ran against a stock `amneziawg-go` server stood up for the
purpose, so Nova app to Nova server is unproven and the node's own AmneziaWG has
not been switched on. And the built AAR is not published anywhere; what is
pinned is the source it comes from, not a URL to fetch it from.

## Why it exists

`lib/src/core/proxy/singbox/awg_config.dart` has emitted a complete AmneziaWG
endpoint (`type: "awg"`, junk parameters `jc/jmin/jmax`, handshake junk `s1-s4`,
magic headers `h1-h4`, and the 1.5/2.0 decoys `i1-i5`) since the config layer was
written. Every core the app shipped was built from stock SagerNet sing-box,
which has never implemented the protocol. Measured on the previously bundled
`libbox.aar` (SHA-256 `5038c07d3716e2859ea9bd15b7450d5ba707793b1792584568c5044aad738210`):

| string in `jni/arm64-v8a/libbox.so` | old core | this core |
| --- | --- | --- |
| `wireguard` | 811 | 811 |
| `amnezia` | 0 | 585 |
| `jmin` | 0 | 5 |

So a customer granted AmneziaWG got a `.conf` and a QR that worked in the
official Amnezia apps and did nothing in Nova's own app, with no error anywhere.

Method note, because it is easy to measure this wrong: a Go binary keeps all of
its strings in one blob with no separators, so exact-line matching finds nothing,
even for `wireguard`. Only substring counts mean anything, and the useful signal
is a configuration key no other protocol uses, such as `jmin`.

## What is pinned

| Input | Value |
| --- | --- |
| Upstream | `SagerNet/sing-box` tag `v1.13.13` |
| Upstream commit | `78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba` |
| Patch | `tool/core/amneziawg.patch`, SHA-256 `067aa9151015bd9687ad838285097f3b68e7dcd68ef214b2a5069d5bedac817b` |
| AmneziaWG module | `github.com/amnezia-vpn/amneziawg-go v0.2.16` (MIT), `h1:XY6HOq/xtqH8ZXMncRWkjFs85EKdN10NLNnw23kTpE0=` |
| gomobile / gobind | `github.com/sagernet/gomobile` `v0.1.12` |
| Android NDK | `28.0.13004108` |
| JDK | 17 (`build_libbox` refuses anything else) |
| Build tags | upstream's shared set plus `with_awg` |
| ABIs | `arm64-v8a` |

The build script checks the first three by value and stops rather than building
something else: a moved upstream tag or an edited patch is a supply-chain event,
not a build failure.

## The artifact

| Artifact | SHA-256 |
| --- | --- |
| **shipped**: `libbox.aar`, arm64-v8a + armeabi-v7a + x86_64, 71,985,428 bytes | `b25a8d7b0ad237ca05ef10f17ffddeb4cd8f8b5c43108b97ed00d3ae510f590f` |
| the narrower arm64-v8a build, 23,718,629 bytes | `f35973c66527f265f83dd627bb1f6646a76b05e63a27dafdb4a41654140d9e12` |

Built 2026-08-09 on macOS 15 arm64 with Go 1.26.4, NDK 28.0.13004108, JDK
17.0.19. **The build is byte-reproducible on the same toolchain**: a second run
from a fresh clone of the upstream tag produced the identical SHA-256, which is
what `-trimpath`, `-buildid=` and `-buildvcs=false` in `build_libbox` are for.
A different Go minor version will change the bytes without changing the
behaviour, so treat the hash as an identity for one toolchain, and the
AmneziaWG check below as the property that must hold for all of them.

The AAR is not committed (GPL-3.0 and large, see `android/.gitignore`), and CI
builds it from the pinned inputs on every release.

**Read the hashes above as a record of what was built here, not as somewhere to
fetch it from. There is no mirror yet.** What this file actually pins, and what
anybody can act on without a mirror, is the upstream commit, the patch and its
SHA-256 (both in this repo), the toolchain versions, and one build command. That
is enough to rebuild a byte-identical AAR and check it against the table. Until
the artifact is mirrored, the hashes are only good for verifying your own
rebuild.

Mirroring it, the way the server mirrors `mtg`, `mita` and `sing-box`, is a
deliberate act and Vahid's call, not part of a build:

```
gh release upload core-libbox-v1.13.13-awg libbox.aar --repo IRNova/Tools
```

Nothing here has been uploaded.

## ABIs: every one the app runs on now carries a core

The AAR carried arm64-v8a only while Flutter emitted `armeabi-v7a` and `x86_64`
code into the same APK, so the app installed and ran on devices with no proxy
core in the package at all. That is the same defect as shipping a core without
AmneziaWG, one layer down, and 32-bit ARM is not a rounding error in this user
base. The core is now built for all three (`PLATFORMS` in
`tool/core/build-libbox.sh`) and the APK is built with Flutter's default ABI
list, so the two lists match.

Measured, on the same build:

| APK | Size | Runs on | Can connect on |
| --- | --- | --- | --- |
| before this change | 60.9 MB | 3 ABIs | arm64-v8a only |
| **now** | **107.8 MB** | 3 ABIs | 3 ABIs |
| arm64-only alternative | 42.8 MB | arm64-v8a | arm64-v8a |

**The cost is real and it is +47 MB against what shipped before**, on a download
that mostly happens over constrained Iranian networks. The honest alternative is
the third row: build the core and the APK for arm64-v8a only
(`PLATFORMS=android/arm64` plus `flutter build apk --target-platform
android-arm64`), which is smaller than today's release and cannot install on a
device it cannot serve. Both rows are defensible and it is Vahid's call. The one
option that is not on the table is the first row: installing on a device with no
core.

Whichever is chosen, the two lists move together, and the workflow enforces it:
every ABI carrying `libflutter.so` must carry `libbox.so`.

Gradle's `defaultConfig.ndk.abiFilters` is not the lever for this, which cost a
build to learn: Flutter's own Gradle plugin decides the ABI list and overrides
it, measured by setting the filter and getting all three ABIs anyway. The lever
is `--target-platform`. Some plugin libraries (ML Kit, `dartjni`) may still be
packaged for ABIs that have no `libflutter.so`; those cannot reach a running
app, which is why the check keys on `libflutter.so`.

## Rebuilding

```
tool/core/build-libbox.sh [output-path]     # default: android/app/libs/libbox.aar
```

It clones the pinned tag, checks the commit, checks the patch hash, applies it,
runs the source-level AmneziaWG check, builds through gomobile, and then refuses
to write the AAR unless every native library in it actually contains AmneziaWG.
The APK workflow calls the same script and repeats the AAR check even on a cache
hit, so a cached core from before this change cannot ship.

## What the patch contains

Ported from `hiddify-app/hiddify-core/hiddify-sing-box`, and deliberately not by
adopting hiddify-core wholesale (that drags in psiphon, mieru, warp-plus, dnstt
and replaced DNS stacks). Nine files of protocol plus three merge points:

- `transport/awg/` (5 files): the device, the bind, and the two TUN adapters.
- `protocol/awg/endpoint.go`: the sing-box endpoint, including the IPC config
  that carries every junk parameter through to `amneziawg-go`. Hiddify's
  1159-line `common/monitoring` dependency was a single optional line here and
  is dropped.
- `option/awg.go`: the option struct. Its JSON field names are exactly what
  `AwgConfig.toEndpoint` already emitted, which is why no Dart change was needed
  to make AmneziaWG work.
- `include/awg.go` and `include/awg_stub.go`: registration under `with_awg`, and
  an explicit refusal without it.
- Merge points: `constant/proxy.go` (`TypeAwg` and its display name),
  `include/registry.go` (one registration call), and
  `cmd/internal/build_libbox/main.go` (`with_awg` in the shared tag list).
- `cmd/internal/awg_probe/`: the same question the app asks at runtime, asked of
  a host build, so a broken source tree fails before gomobile is ever started.

**One correction to the ported code, and it is the reason a config check is not
a proof.** Hiddify's `Endpoint.Start` returns without starting the device (the
call is commented out in their source). The embedded `*awg.Device` and the
embedded `endpoint.Adapter` both carry a `Start`, so an explicit method has to
exist to resolve the ambiguity, and theirs resolved it to nothing. The result
passes every static check: the config parses, the endpoint builds, the userspace
stack accepts connections, and not one packet is ever sent. It was found by
driving real traffic, not by reading. `Start` now forwards to the device, the
way `protocol/wireguard` drives its own endpoint.

**And a second one, which only a phone could have shown.** With the forward in
place the device came up at `StartStateStart`, and on Android that is before the
VpnService has reported its default network interface, so opening the bind's UDP
sockets failed with "no available network interface" on a device that was
perfectly online. The device now starts at `StartStatePostStart`, which is where
upstream's WireGuard endpoint does its own connecting half. The client side of
the same race is fixed in `NovaVpnService.startDefaultInterfaceMonitor`, which
now reports the network it can already see synchronously instead of waiting for
the first `onAvailable` callback: every registration delivers that on a handler,
so a fast start can outrun it. Before the two fixes the emulator connected once
in three attempts; after them, three for three.

**A third, found by the security pass and reproduced before it was believed.**
`Device.Close` dereferenced `awgDevice` without a nil check, and the endpoint
manager closes an endpoint it registered but never post-started. So any failed
start with an AmneziaWG profile panicked inside `Box.Close`, and sing-box's
`Box.Start` recovers that panic and then returns its unnamed nil result: the
core reported success, the app showed **Connected**, and there was no tunnel at
all. Reproduced by giving the client an inbound that cannot bind: before the
fix, the stack trace and then a process that carried on as though it had
started; after it, `FATAL start service: ... bind: permission denied`, which is
the truth. `Close` is now total and releases the tun as well.

## The proof that it carries traffic

`sing-box check` and a strings count both passed on the version that could not
send a packet, so neither is the proof. What was measured, on 2026-08-09:

- A real AmneziaWG server, `amneziawg-go` v0.2.16 in userspace with an HTTP
  server behind it, on `udp/51820`, with `jc=4 jmin=40 jmax=70 s1=15 s2=20` and
  magic headers `h1-h4`.
- A client built from this exact patched tree, configured through the same
  option shape `AwgConfig.toEndpoint` emits, with a SOCKS inbound routed to the
  `awg` endpoint.
- `curl` through that SOCKS inbound returned the page from inside the tunnel,
  `HTTP 200`, the server seeing the request from the tunnel address `10.9.0.2`,
  and its log recording a completed handshake.
- Changing only `h1` on the client broke it completely (timeout, no handshake),
  which is what says the obfuscation parameters really reach the wire instead of
  being parsed and dropped. A plain WireGuard implementation would have ignored
  `h1` and connected.

Then the same thing through the app itself, on an Android 15 arm64 runtime with
the built AAR installed, driven by
`integration_test/android_awg_core_test.dart`:

- the core answered the capability probe with AmneziaWG supported, version
  1.13.13,
- `SingboxConfig.build` on an imported `.conf` produced the `awg` document, the
  app started its own `VpnService` with it, and the tunnel reached `connected`,
- an HTTP request from inside the app came back through the tunnel, the server
  seeing it from `10.9.0.2`, and the server's log recording the handshake from
  the phone,
- and the traffic counters on the app's own event channel moved.

**What none of this is: a Nova node.** The peer was a stock `amneziawg-go`
server stood up for the test. Nova's own node has AmneziaWG installed but was
switched off, and turning it on is the operator's call, so the last mile,
Nova's app to Nova's server, is still unproven. Everything between the Dart
layer and the wire is proven.

## How a future mismatch becomes visible

Three independent gates, because the failure mode is silence:

1. **Source**: `cmd/internal/awg_probe` fails if the patched tree cannot build an
   AmneziaWG endpoint.
2. **Artifact**: `tool/core/build-libbox.sh` and the APK workflow both fail if
   any `libbox.so` in the AAR lacks AmneziaWG.
3. **Runtime**: the app asks its own core. `NovaCore.supportsAwg` hands libbox a
   minimal AmneziaWG endpoint through `Libbox.checkConfig`; the Dart
   `CoreFeatures` reads the answer over the `coreFeatures` method channel, and
   `SingboxProxyController` refuses to hand an AmneziaWG document to a core that
   says it has none, naming the cause instead of producing a tunnel that comes
   up and carries nothing. `test/core_features_test.dart` pins all of it.

A host that has no probe (iOS, macOS, Windows, Linux) answers nothing, which is
recorded as unknown and never blocks a connection. That is not a claim those
cores support AmneziaWG: **the Windows core is still the stock
`assets/bin/sing-box-windows-amd64.exe` and the Apple cores are still stock**,
so AmneziaWG on those platforms remains unbuilt, not merely unmeasured.

## The desktop cores

Until v1.3.0-beta the macOS and Windows binaries in `assets/bin` were **stock
sing-box, built with `with_gvisor,with_quic,with_utls,with_clash_api,with_grpc`
and nothing else** (read from the `-tags=` string Go embeds in the binary). No
`with_wireguard`, so a plain WireGuard config made the desktop core exit with
"WireGuard is not included in this build"; no `with_naive_outbound`, so a
NaiveProxy server did the same; and no AmneziaWG at all. The app's config layer
had emitted all three for months. `tool/core/build-desktop.sh` now builds both
from the same pinned tag and patch as `build-libbox.sh`:

| Target | Link model | Tags |
| --- | --- | --- |
| macOS arm64 | cgo, cronet linked statically (`lib/darwin_arm64/libcronet.a`), so it must be built on a Mac | the Android set plus `with_grpc` |
| Windows amd64 | `CGO_ENABLED=0`, cross-compiled, plus `with_purego`; cronet is loaded at runtime from `libcronet.dll` beside the exe (shipped in `assets/bin`, mirrored into the run directory by the desktop controller, bundled by the Windows workflow) | the same, plus `with_purego` |

`sing-box version` on either reports `1.13.13-nova`. The script runs `check` on
a probe document carrying an `awg` endpoint and a `naive` outbound and refuses
to hand back a core that answers "not included in this build" (on the Windows
binary, which cannot execute here, it falls back to the same string evidence as
the Android build).

Two things the desktop CLI enforces that libbox on the phones only warns about,
both found by running `check` on the app's real output:

- **The legacy DNS server format** the app still emits is a fatal on the 1.13
  CLI unless `ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true`. The desktop
  controller sets it for every launch path (plain, elevated macOS, elevated
  Windows). The real fix is migrating `dns.servers` to the 1.12 typed format on
  every platform, and that must land before any 1.14 core, which removes the
  legacy form.
- **`route.default_domain_resolver`** is required, and independently required by
  the NaiveProxy outbound because cronet does its own dialing. The config layer
  now emits `{"server": "local"}` for every platform, which restates what the
  DNS rules already did with every proxy server's hostname.

NaiveProxy's TLS block is bare on purpose: the outbound rejects `alpn`, `utls`,
`fragment` and `insecure` ("<x> is not supported on naive outbound"). The last
of those means a NaiveProxy server on a self-signed certificate cannot be dialed
by this core at all; the app refuses such a node with the reason instead of
starting a core that fails every dial.

At connect the desktop controller no longer assumes what its core can do: it
runs the same probe document through `check` once per binary and type, and
gates AmneziaWG and NaiveProxy on the answer, so a swapped or stale binary is
named rather than guessed at.

## The nova_fragment patch (exact TLS fragmentation)

`tool/core/novafrag.patch` (SHA-256 pinned in both build scripts) is applied on
top of `amneziawg.patch`. It adds `transport/internet/novafrag`, a faithful port
of Xray-core's `finalmask` fragment, and a new outbound TLS option
`nova_fragment` that carries the exact stages (packets / lengths / delays /
maxSplit). This exists because sing-box's own `record_fragment` splits the
ClientHello at random points near the SNI and cannot take explicit byte lengths;
on strict DPI (Iran MCI) that was not enough, while Xray's byte-exact split (as
PattNG sends it) got through. With this, a Nova config carrying the same `fm=`
mask produces the same bytes on the wire as PattNG.

- The patch touches 4 files (novafrag.go new, plus option/tls.go and the std /
  utls TLS clients) and is verified by a unit test that the ClientHello splits
  into TLS records of 5, 94, 1 bytes and then TCP segments of 109, 1 bytes.
- No build tag: novafrag is in `common/tls`, always compiled, so every rebuilt
  core has it. `jmin`/`naive` still gate AmneziaWG/NaiveProxy by tag as before.
- The Dart hardened TLS block emits `nova_fragment` from the node's own `fm`
  mask when present, else the field-tested default; on Windows only the
  `tlshello` record stage is kept (the segment stage needs an ACK-wait an
  unelevated Windows core cannot drive).

## Rebuilding the iOS core (Novacore.xcframework)

There was no in-repo recipe for the iOS core. It binds
`github.com/sagernet/sing-box/experimental/novacore`, which is NOT in stock
sing-box: it is `experimental/libbox` copied with `package libbox` renamed to
`package novacore` (a de-fingerprinting rename). To rebuild: in the patched
tree, `cp -R experimental/libbox experimental/novacore`, sed the package name,
then `gomobile bind -target ios,iossimulator -libname=core -o Novacore.xcframework
./experimental/novacore` with build_libbox's shared+darwin tag set (gomobile /
gobind v0.1.12, JDK 17). The exported ObjC API is unchanged by the rebuild
(novafrag adds no exported symbols), so the existing NovaProxyHost / PacketTunnel
Swift links against it as-is. Script kept at tool/core (build-novacore-ios).

## 2026-08-18: fixed a crash on disconnect (double-close of the tun)

Users reported the app crashing and closing whenever they disconnected an
AmneziaWG profile (Android), and macOS showed it directly in the UI as
`panic on early start: close of closed channel` alongside
`close endpoint/awg[proxy] take too much time to finish`.

Reproduced with `sing-box run` on an `awg` endpoint plus SIGINT, which gave the
full Go trace:

    panic: close of closed channel
      gvisor .../link/channel.(*queue).Close
      gvisor .../link/channel.(*Endpoint).Close
      amneziawg-go/tun/netstack.(*netTun).Close
      sing/common.Close
      sing-box/transport/awg.(*Device).Close   <- ours
      sing-box/adapter/endpoint.(*Manager).Close

Cause: `amneziawg-go`'s `device.Device.Close()` closes the tun it was handed
(`device.tun.device.Close()` is the first thing it does). Our `Device.Close()`
then called `common.Close(d.tun)` on the same tun, closing the gvisor channel
queue twice. gvisor's `queue.Close` is not idempotent, so the second close
panics. The core runs in-process on Android and desktop, so the panic took the
whole app down rather than surfacing as an error.

Fix: only close the tun ourselves when no awg device ever took ownership of it,
and clear both fields so a second `Close` is a no-op. Verified with five
start/stop cycles: zero panics, clean worker shutdown.
