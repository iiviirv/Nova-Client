# The macOS Network Extension

Nova's tunnel on the Mac runs in a system extension, which is why the Mac stops
asking for an administrator password on every connect, and why "Nova" appears in
System Settings > Network next to Wi-Fi like any other VPN.

Creating a tunnel device needs root. Before this, Nova got there with an
AppleScript administrator prompt on every single connect. A system extension is
approved once by the user and started by macOS from then on.

## Shape

    macos/NovaTunnel/            the extension: main.swift, PacketTunnelProvider,
                                 Info.plist, entitlements
    macos/Runner/NovaTunnelHost  the app side: activate, start, stop, status
    lib/.../mac_tunnel_extension.dart   the Dart channel
    macos/Frameworks/Novacore.xcframework  the core, built for macOS

The provider is a near-copy of the iPhone one (`ios/NovaTunnel`), deliberately:
same core, same libbox platform interface, same behaviour. It differs in three
places only, each marked in the file.

The extension runs the same config the bundled core ran, Clash API included, so
the desktop controller's traffic, latency, health and server board all work
against it unchanged. Proxy mode still runs the core as a child process; only
whole-device mode goes through the extension.

## Building

    tool/core/build-combined-core-ios.sh macos    # the core framework
    flutter build macos --release                 # app + extension

The framework is gitignored (160MB), like the iOS one.

## Six things macOS insists on, each of which is a wasted afternoon

1. **The extension bundle must be named for its bundle identifier.** Not
   `NovaTunnel.systemextension` but
   `online.novaproxy.novaClient.NovaTunnel.systemextension`. Named anything else,
   activation fails with "Extension not found in App bundle" while the bundle is
   sitting right there with the correct identifier inside it.
2. **`NSSystemExtensionUsageDescription` in BOTH Info.plists.** The app's alone is
   not enough: the request is refused with "extensions belonging to the
   network_extension category require the presence of the
   NSSystemExtensionUsageDescription property".
3. **A system extension is an executable, not a plug-in.** It needs a `main.swift`
   that calls `NEProvider.startSystemExtensionMode()`. Without it the target does
   not even link ("Undefined symbol: _main").
4. **The app must be notarized.** Not just Developer ID signed: an unnotarized
   build fails activation with "code signature invalid", which sounds like a
   signing mistake and is not one.
5. **Do not embed the core framework in the extension.** gomobile emits a STATIC
   framework, so it is linked into the extension's binary; embedding it as well
   copies an ar archive into Contents/Frameworks that cannot be signed properly,
   and notarization rejects it.
6. **Sign a versioned framework at `Versions/A`,** not at the wrapper. Signing the
   wrapper leaves the real binary with its build-time signature, and notarization
   answers "the signature does not include a secure timestamp".

## Signing

Both profiles are Developer ID (`MAC_APP_DIRECT`) and were created through the
App Store Connect API:

- `Nova macOS App DirectID` for `online.novaproxy.novaClient`, carrying
  `com.apple.developer.system-extension.install`.
- `Nova macOS Tunnel DirectID` for `online.novaproxy.novaClient.NovaTunnel`,
  carrying `packet-tunnel-provider-systemextension`.

Both App IDs already had the Network Extensions capability on team A53J987N2C,
so nothing had to be requested from Apple. Xcode embeds each profile at build
time; `tool/release_macos.sh` refuses to continue if either is missing.

## What the provider needs that nothing tells you

Getting the extension installed is half of it. Getting macOS to actually start
the provider took five more, each of which reached the app as the same "the
tunnel did not come up", and none of which appears in any log:

1. **The app needs the Network Extension entitlement too**, not just the
   extension. Without it, saving the VPN configuration fails with "permission
   denied" while the extension sits there installed and approved.
2. **That entitlement cannot coexist with
   `com.apple.security.cs.disable-library-validation`.** macOS kills the app at
   spawn: no crash report, no log, "Launchd job spawn failed".
3. **Re-signing must carry `com.apple.application-identifier` and
   `com.apple.developer.team-identifier`.** Xcode injects them from the profile;
   an entitlements file that omits them drops what the profile is matched
   against, and the app is killed the same silent way.
4. **`NEMachServiceName` must begin with one of the extension's app groups**, so
   it is the app group itself. The extension's own identifier reads more
   naturally and is rejected outright: "extension category returned error".
5. **The config cannot be handed over through the App Group container.** The
   extension runs as root, so its container is
   `/private/var/root/Library/Group Containers/...`, a different directory from
   the app's. It travels in `providerConfiguration` instead.
6. **Rule sets have to live inside the extension bundle.** A network extension is
   sandboxed out of the user's home, so the copies the app leaves there are
   unreadable to it ("operation not permitted") and the core refuses to start
   the router at all.

And macOS will not swap a running system extension for a rebuilt one: it answers
`willCompleteAfterReboot` and keeps the copy it has. The app deactivates and
reactivates instead, which it does honour immediately. Every rebuild also has to
be notarized before macOS will consider it.

## Proof it works

    startTunnel
    setup done err=none
    config from providerConfiguration (3374 bytes)
    command server created
    service started

    $ scutil --nc status "Nova"        Connected
    $ curl https://api.ipify.org       164.90.169.98   <- the server, not the Mac
    $ curl 127.0.0.1:9191/version      sing-box ... -nova

Full-device mode, an AmneziaWG server, traffic on the machine's own interface,
and no password asked at any point.

## The user's one interaction

The first connect in whole-device mode asks macOS to install the extension.
macOS enrols it and waits:

    $ systemextensionsctl list
    A53J987N2C  online.novaproxy.novaClient.NovaTunnel (0.9.23/123)  [activated waiting for user]

Until the user allows it in System Settings > General > Login Items and
Extensions > Network Extensions, Nova connects the old way and says so. After
they allow it, no password is ever asked again.
