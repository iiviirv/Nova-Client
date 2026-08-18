# mieru protocol support (plan)

Nova Server can emit `mieru://` configs, but neither sing-box (mainline) nor
Xray implements mieru, so the client only counts it as a skipped/unsupported
scheme (`subscription.dart`). This is the plan to make mieru a first-class,
connectable protocol across all four clients.

## Approach: port the mieru outbound into Nova's sing-box as a patch

mieru IS implemented for sing-box in the upstream author's fork
**`enfein/mbox`** (`module github.com/sagernet/sing-box`), which is based on
**sing-box 1.13** (its go.mod pins `sing-box-1.13-mod` deps). Nova's core is
sing-box **v1.13.13**, so the versions line up and the outbound ports cleanly,
the same way `amneziawg.patch` adds AmneziaWG.

From mbox:
- `protocol/mieru/outbound.go` (+ `inbound.go`, which we don't need) implements
  the `type: "mieru"` outbound.
- go.mod adds `github.com/enfein/mieru/v3 v3.36.0` (pulls `sagernet/smux` etc.).

Concretely (a new `tool/core/mieru.patch`, applied like the AWG patch):
1. Copy `protocol/mieru/outbound.go` into Nova's sing-box tree.
2. Register the outbound in sing-box's outbound registry (mbox's registration).
3. Add the mieru option struct to `option/` (server, server_port, transport
   TCP/UDP, username, password, multiplexing, traffic-pattern, mtu).
4. `go mod edit -require github.com/enfein/mieru/v3@v3.36.0` + `go mod tidy`.
5. Build with mieru compiled in and VERIFY the symbol is present (mirror the
   `jmin`/`splithttp` checks in `build-combined-core.sh`).

Build scripts to touch: `build-combined-core.sh` (Android AAR),
`build-combined-core-ios.sh` (iOS xcframework), `build-desktop.sh` (desktop CLI).
Same three cores as the AmneziaWG + Xray work.

## The `mieru://` / `mierus://` URI formats (from enfein/mieru discussion #60)

- **Standard**: `mieru://<base64>` where the base64 is the full mieru client
  JSON config (profiles -> user{username,password}, servers[{ipAddress|domainName,
  portBindings[{port|portRange, protocol: TCP|UDP}]}], mtu, multiplexing).
- **Simple**: `mierus://username:password@server?profile=..&port=..&protocol=..&
  mtu=..&multiplexing=..&handshake-mode=..&traffic-pattern=..#name`. `port`+`protocol`
  repeat and pair by position; ranges as `portRange=2090-2099`.

Which one Nova Server emits must be confirmed with a real example from the panel
(the client currently only tallies the `mieru` scheme). Support both to be safe.

## Dart changes (only AFTER the core supports it, so we never ship "parses but
can't connect")

- `proxy_node.dart`: add `NodeProtocol.mieru` + fields (username, password,
  transport, multiplexing, portList/protocolList or a single port+transport).
- `share_link.dart`: parse `mieru://` (base64 JSON) and `mierus://` (query) into
  a `ProxyNode`; add the `switch` cases.
- `singbox_config.dart`: emit the `type: "mieru"` outbound (server, server_port,
  transport, username, password, multiplexing). UDP transport implies the QUIC
  path; keep QUIC escape rules consistent with Hysteria2/TUIC.
- `node_probe.dart`: mieru is a custom obfuscated transport, so it is
  untestable from outside; return `untestable('verified when you connect')`
  like AmneziaWG/xhttp (do NOT fake a probe).
- `core_features.dart`: add a `usesMieru` gate + a clear "core lacks mieru"
  message, mirroring `usesAwg`, so an old core fails gracefully.

## Open items / what's needed to finish

1. A real `mieru://` example from Nova Server to pin the exact encoded structure.
2. Confirm `enfein/mbox`'s `protocol/mieru/outbound.go` applies to v1.13.13 (build it).
3. The gomobile AAR + iOS xcframework + desktop rebuilds (~25 min each) and an
   on-device connect test against a live mieru server.

## Test plan

Build the core with mieru; add a mieru node (from a real link); connect; confirm
traffic flows (curl through the tunnel), on Android emulator + a desktop build.
