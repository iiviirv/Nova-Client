# Nova Client on iOS, status and plan

iOS uses Apple's **Network Extension** (a Packet Tunnel Provider) to run the
sing-box core, the iOS equivalent of the Android VpnService. The Flutter app
talks to it over the same `nova.proxy/control` MethodChannel the Android host
uses, so once the extension is wired, iOS shares all the app UI and Dart logic.

## Done
- **Core built**: `Libbox.xcframework` (device arm64 + simulator) is generated and
  placed in `ios/Frameworks/` (gitignored, rebuildable). It exposes the same
  `Libbox` API the Android `.aar` does.

### Rebuild the core
```sh
git clone --depth 1 -b v1.11.15 https://github.com/sagernet/sing-box.git
cd sing-box
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.4
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.4
PATH="$PATH:$(go env GOPATH)/bin" go run ./cmd/internal/build_libbox -target apple -platform ios
cp -R Libbox.xcframework /path/to/Nova-Client/ios/Frameworks/
```

## Remaining (in Xcode, needs the Apple Developer account: @irnova_proxy)
1. **Add a Packet Tunnel target**: File > New > Target > Network Extension >
   Packet Tunnel Provider (e.g. `NovaTunnel`). Embed it in Runner.
2. **Capabilities** on both Runner and the extension:
   - Network Extensions (Packet Tunnel)
   - App Groups (e.g. `group.online.novaproxy.client`) so the app and the
     extension share the profile/config and stats.
3. **Link `Libbox.xcframework`** into the extension target ("Do Not Embed", it's
   a static-ish Go framework).
4. **PacketTunnelProvider.swift** (in the extension): start the sing-box instance
   with the config from the app group, implementing the libbox PlatformInterface
   over the `NEPacketTunnelFlow`. The canonical reference is sing-box's own iOS
   app (`sing-box-for-apple`, the `ExtensionProvider`), which can be adapted
   nearly verbatim against this same `Libbox.xcframework`.
5. **App-side host** (in Runner): a `NovaProxyHost.swift` implementing the
   `nova.proxy/control` MethodChannel via `NETunnelProviderManager`
   (start/stop/status) and the `nova.proxy/events` EventChannel for state +
   traffic (read from the app group, written by the extension).
6. **Signing**: sign Runner + the extension with the team from the Apple account.
   A real device is needed for full testing (the simulator's NE support is
   limited).
7. **Flip the controller**: in `lib/main.dart`, route iOS to
   `SingboxProxyController()` (the MethodChannel client) instead of the mock.

After step 7 the existing Flutter UI (dashboard, profiles, Cloudflare, radar,
onboarding) drives the iOS tunnel with no further UI work.
