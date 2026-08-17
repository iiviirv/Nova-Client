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
app-support and chmod +x. Today only `assets/bin/xray-macos-arm64` (Xray 26.3.27)
ships; `tool/release_macos.sh` copies and codesigns it alongside the sing-box core.

Verified on macOS: `xray run -test -c` reports "Configuration OK" for the exact
config `XrayConfig.buildMap` emits, and the shipped binary binds SOCKS 10808 at
runtime. The data path itself (TUN -> sing-box -> SOCKS -> Xray -> internet) was
proven earlier by the mobile on-device pass and the Mac loopback test.

## Follow-ups (not done)

1. **Windows/Linux binaries.** Only macOS arm64 xray ships. `_startXray` returns a
   clear "no Xray core on <os>" message on the others. Add
   `xray-windows-amd64.exe` / `xray-linux-amd64` to `assets/bin/`, bundle them in
   the Windows/Linux packaging, and (Windows) codesign.
2. **TUN (whole-device) mode.** xhttp is refused in TUN mode today: sing-box's TUN
   would capture Xray's own outbound dials and loop. To support it, exclude Xray's
   destination IPs (the resolved server IP) from the sing-box tunnel route, the
   same way the mobile core route-excludes the bridge. Until then, the app tells
   the user to turn off TUN mode for an xhttp server.
3. **Pool case on desktop.** Only the single/pinned xhttp node is wired. Mixing an
   xhttp node into a multi-node auto-select pool (as mobile does via
   `XrayConfig.buildMulti` + one SOCKS outbound per node in sing-box's urltest)
   is not yet done on desktop.
</content>
</invoke>
