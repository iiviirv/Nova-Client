# iOS repositioned + fresh-record: execution checklist

Decision (2026-08-17): submit a **repositioned** app ("Nova Edge") as a **new app
record** on an **organization account**, not a resubmission of the current record.
Rationale and metadata: `appstore-4.3-repositioning.md`. Do NOT resubmit the old
binary on the current account (account-jeopardy risk).

Current identity (what changes away from):
- App bundle id: `online.novaproxy.novaClient`
- Extension bundle id: `online.novaproxy.novaClient.NovaTunnel`
- App Group: `group.online.novaproxy.novaClient`
- Display name (CFBundleName): `Nova Client`
- Old app record: App ID `6785367637` (individual account) — leave it; cancel its
  pending submission, do not resubmit.

## A. You (Apple account — I can't log in or submit)

1. **Enroll an Organization** in the Apple Developer Program (needs a D-U-N-S
   number). Required by Guideline 5.4 for VPN apps and distances you from the
   flagged individual-account history.
2. Decide the **new bundle-id prefix** (your org reverse-domain), e.g.
   `com.<org>.novaedge`. Give me that prefix and I do step B.
3. In App Store Connect on the org account: create a **new app record** named
   **Nova Edge** with the new bundle id, and fill metadata from
   `appstore-4.3-repositioning.md` (subtitle, keywords, promo, description, review
   notes).
4. Register the new **App Group** (`group.<new-bundle-id>`) and let Xcode create
   provisioning for the app + the NovaTunnel extension.
5. Cancel the pending submission on the OLD record (App ID 6785367637). Keep the
   record; just don't resubmit it.

## B. Me (code) — DONE 2026-08-17

Applied the iOS rename to bundle-id prefix **`tech.innovatenorth.novaedge`**:
- `ios/Runner.xcodeproj/project.pbxproj`: all 9 bundle ids
  (`tech.innovatenorth.novaedge`, `.NovaTunnel`, `.RunnerTests`).
- App Group → `group.tech.innovatenorth.novaedge` in `Runner.entitlements`,
  `NovaTunnel.entitlements`, and the two Swift `appGroup` consts
  (`NovaProxyHost.swift`, `PacketTunnelProvider.swift`); the hardcoded
  `tunnelBundleId` in `NovaProxyHost.swift` updated too.
- Display name **Nova Edge** (CFBundleDisplayName in `ios/Runner/Info.plist`).
- Verified: plists/entitlements lint OK, pbxproj valid, `flutter analyze` clean.

Deliberately NOT changed (out of scope / cross-platform):
- macOS and Android identity (macOS ships Developer-ID, not App Store; Android
  package `online.novaproxy.nova_client` unchanged).
- The `novaclient://oauth-return` URL scheme (shared by Dart + iOS/Android/macOS
  for the Cloudflare sign-in return; changing it would touch that flow on every
  platform for a marginal 4.3 gain). CFBundleName stays `nova_client` (internal).

A real iOS build/sign can only happen after the org account is approved and the
new bundle id + App Group are registered/provisioned on it.

## C. Get build 82 onto TestFlight (after A + B)

TestFlight needs an uploaded, signed build on the new record. There is no iOS CI
today, so this is a local archive + upload:

1. `flutter build ipa --release` (or Xcode Archive) signed with the org
   distribution cert + the new provisioning.
2. Upload with Xcode Organizer or Transporter to the new record.
3. Once it finishes processing, add internal testers (immediate) and an external
   group (external needs a light Beta App Review, not the 4.3 gate).

TestFlight has **no 4.3 gate**, so testers can have the latest build even while the
store submission is pending or uncertain.

## D. Parallel paths that work today (no App Store dependency)

Sideload / AltStore, and EU alternative marketplaces. Keep these open; per the
package, treat the App Store itself as a maybe even with everything above done.
