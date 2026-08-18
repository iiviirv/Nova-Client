# Desktop Xray binding (xhttp on macOS/Windows/Linux)

xhttp (SplitHTTP) is an Xray-only transport; sing-box cannot run it. On mobile the
app already runs two cores for these servers: sing-box owns the TUN and bridges its
inbound to a local SOCKS port that Xray serves, and Xray does the real xhttp. This
note records the same wiring on desktop.

## What ships now (macOS, proxy mode)

`lib/src/core/proxy/desktop_proxy_controller.dart`:

- When the single/pinned exit node is `network == 'xhttp'`, the controller:
  1. resolves the node's server host to an IPv4 (`_resolveXhttpServer`) so Xray has
     a numeric server before the tunnel is up (SNI/Host stay the domain),
  2. builds the Xray config with `XrayConfig.build(node, socksPort: 10808)` into
     `_pendingXrayConfig`,
  3. builds the sing-box side with `SingboxConfig.buildXraySocksBridgeMap(10808)`
     (its inbound forwarded to Xray's local SOCKS), and
  4. starts Xray first (`_startXray`) so its SOCKS inbound is up before sing-box
     dials it, then starts sing-box as usual.
- Xray runs as its own process (`_xrayProcess`), its stdout/stderr piped into the
  Core log with the `xray` label (same blocked-noise filter as sing-box).
- `_cleanup` stops Xray via `_stopXray`.

Binary staging mirrors the sing-box core: `_bundledXrayBinary` / `_ensureXrayBinary`
look for `xray-<os>-<arch>` in the app bundle (macOS `Contents/Resources/`, Windows
next to the exe, else `assets/bin/` when running from source), copy it into
app-support and chmod +x. All three desktop binaries ship, built from one pinned
xray-core version (`tool/core/build-xray-desktop.sh`, which reads the version from
the mobile wrapper's `go.mod` so the cores never drift):

- `assets/bin/xray-macos-arm64` — `tool/release_macos.sh` copies and codesigns it
  alongside the sing-box core.
- `assets/bin/xray-windows-amd64.exe` — `.github/workflows/build-windows.yml`
  copies it next to the `.exe`.
- `assets/bin/xray-linux-amd64` — for the from-source Linux run (no packaged Linux
  release today); `_bundledXrayBinary` finds it under `assets/bin/`.

To rebuild all three: `tool/core/build-xray-desktop.sh all`.

Verified on macOS: `xray run -test -c` reports "Configuration OK" for the exact
config `XrayConfig.buildMap` emits, and the shipped binary binds SOCKS 10808 at
runtime. The data path itself (TUN -> sing-box -> SOCKS -> Xray -> internet) was
proven earlier by the mobile on-device pass and the Mac loopback test.

## Follow-ups

1. ~~**Windows/Linux binaries.**~~ Done: all three desktop binaries ship (built by
   `tool/core/build-xray-desktop.sh all`) and are bundled by their packaging steps.
2. ~~**TUN (whole-device) mode.**~~ Done: xhttp works in TUN mode too. The bridge
   config routes the resolved server IP `direct` (`buildXraySocksBridgeMap`'s
   `directServerIp`), so Xray's own dial to the server, captured by the tunnel,
   exits on the real interface instead of looping back into the socks->Xray chain.
3. **Pool case on desktop.** Only the single/pinned xhttp node is wired. Mixing an
   xhttp node into a multi-node auto-select pool (as mobile does via
   `XrayConfig.buildMulti` + one SOCKS outbound per node in sing-box's urltest)
   is not yet done on desktop.
</content>
</invoke>
