# iOS home-screen widget (WidgetKit)

Mirrors the Android status widget: a small/medium home-screen widget that shows
whether Nova is connected, updated live, that opens the app when tapped.

## What is already in the repo

- `ios/NovaWidget/NovaWidget.swift` - the WidgetKit widget (TimelineProvider +
  SwiftUI view). Reads the state the app publishes into the shared App Group and
  draws the brand ribbon "N" with the gradient. No polling: it refreshes when the
  app calls `WidgetCenter.reloadAllTimelines()`.
- `ios/NovaWidget/Info.plist` - the extension plist (`widgetkit-extension`).
- `ios/NovaWidget/NovaWidget.entitlements` - the App Group
  (`group.tech.innovatenorth.novaedge`), the same one the app and tunnel share.
- App side (`ios/Runner/NovaProxyHost.swift`): `publishWidgetState(_:)` writes
  `nova.widget.state` and `nova.widget.label` into the App Group `UserDefaults`
  on every `NEVPNStatus` change and reloads the widget. The profile name is read
  from the `start` call's `label` arg (already sent by the Dart controller).

## What still has to happen in Xcode (needs the org account)

These steps are deliberately NOT scripted into `project.pbxproj` by hand, because
a mis-added target cannot be caught without an iOS build. Do them in Xcode:

1. **Add the target.** File > New > Target > **Widget Extension**. Name it
   `NovaWidget`, uncheck "Include Configuration Intent" (this widget is static),
   embed it in the `Runner` app. Delete the boilerplate files Xcode generates and
   add the three files already in `ios/NovaWidget/` instead.
2. **Bundle id.** Set it to `tech.innovatenorth.novaedge.NovaWidget` (a child of
   the app id, matching the `.NovaTunnel` extension pattern).
3. **App Group.** In Signing & Capabilities for the new target, add the App Group
   capability and tick `group.tech.innovatenorth.novaedge`, and point the target
   at `ios/NovaWidget/NovaWidget.entitlements`.
4. **Deployment target.** iOS 14+ (WidgetKit). The widget guards `WidgetCenter`
   with `if #available(iOS 14, *)` on the app side, so the app itself keeps its
   existing minimum.
5. **Provisioning.** The new bundle id + App Group must be registered on the
   **organization** developer account (the same one the Nova Edge rename waits
   on). Until the org account is approved, the widget target cannot be signed.

## Verify (after the org account is live)

- Build the app to a device, add the "Nova status" widget to the home screen.
- Connect: the widget should flip to "Connected" (and the profile name) within a
  second; disconnect returns it to "Not connected".
- Tapping the widget opens the app.

## Not gated on this

The Android widget is already shipped and works today; this is iOS parity only.
