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

## The user's one interaction

The first connect in whole-device mode asks macOS to install the extension.
macOS enrols it and waits:

    $ systemextensionsctl list
    A53J987N2C  online.novaproxy.novaClient.NovaTunnel (0.9.23/123)  [activated waiting for user]

Until the user allows it in System Settings > General > Login Items and
Extensions > Network Extensions, Nova connects the old way and says so. After
they allow it, no password is ever asked again.
