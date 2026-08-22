# iOS: migrating the Apple membership to the organization (and shipping through it)

**Case:** Apple Developer Support 20000140213225, advisor Shabir
(devprograms@apple.com). Reply sent 2026-08-19 asking them to start.

**State as of 2026-08-21: Apple has started it, and the ball is with us.**

Two mails arrived that afternoon.

Shabir, Developer Support, 13:20:

> I understand that you would like to start the migration process and I am more
> than happy to initiate your request. You should have received a
> system-generated email with a link to enroll your company in our program. Keep
> in mind that **you won't have access to the Certificates, Identifiers &
> Profiles portal until the migration is complete.** After you submit your
> company enrollment information, we'll contact you with the next steps.

The system mail, 13:15:

> We received your request to assign your Program License Agreement to an
> organization. To continue, update your enrollment with your organization
> information. Please note that **your membership benefits will be temporarily
> disabled until the assignment process is complete.**

So the remaining step is ours: follow the enrollment link and submit Innovate
Northtech Inc. (D-U-N-S 245850078). Shabir asked us to reply on the case to
cancel, or if the enrollment throws an alert.

**Submitted 2026-08-22. Enrollment ID `ZS95GQN5L5`.** Apple pulled everything
but the name and D-U-N-S from the D&B record, so what is now on file with them
is:

| Field | Value |
| --- | --- |
| Legal entity type | Company / Organization |
| Legal entity name | Innovate Northtech Inc. |
| D-U-N-S | 245850078 |
| Address | 277 Miami Dr, Keswick, ONTARIO, L4P 2Z5, CA |
| Website | www.innovatenorth.tech |
| Phone | +1 (647) 916-2690 |
| Signature-authority reference | vahid@innovatenorth.tech |

Apple's confirmation: "Once we verify your authority to sign legal agreements,
we'll email you with instructions on how to complete your enrollment." So the
next move is theirs.

**The blackout has started.** Certificates, Identifiers & Profiles now answers:

> Unable to find a team with the given Team ID 'A53J987N2C' to which you belong.

Automatic signing talks to that portal, so `flutter build ipa` may fail from
here until the migration completes. Use the manual-signing fallback below. The
last build made before the cutoff was **0.5.0 (91)**, signed and installed on
the iPhone, and its IPA is in `build/ios/ipa/` if it is needed for TestFlight.

**What is migrating:** the individual membership, Team ID `A53J987N2C`
("VAHID HASHEMI"), to an organization membership for **Innovate Northtech Inc.**
(D-U-N-S 245850078, https://innovatenorth.tech).

## Why this matters

The App Store submission of Nova (0.3.3) came back under Guideline 4.3(a) Spam
and is currently `Developer Rejected` in App Store Connect. That outcome is tied
to the individual account: a VPN client on the App Store is expected to come from
an organization, and the App Store review guidelines for VPN apps
(5.4) are written around a company. The migration is the unblock; nothing in the
app itself changes for it.

Side effect worth having: after migration the **legal entity name** (Innovate
Northtech Inc.) replaces the personal name on the store listing.

## What Apple told us, and where we stand

| Requirement | State |
| --- | --- |
| Two-factor auth on the membership's Apple Account | on |
| Public organization website on the org's own domain | https://innovatenorth.tech, live |
| Certificates, Identifiers & Profiles offline during migration | see the blackout plan below |
| Legal entity name applied to all apps afterwards | intended |
| Individual Sales/Trends reports lost | irrelevant, the app is free |
| Pre-migration earnings routing | irrelevant, no paid apps or IAP |

App Store Connect and TestFlight stay available throughout, so testers keep
getting builds that are already uploaded.

## The blackout plan (building iOS while the portal is down)

`flutter build ipa` uses **automatic** signing (`ios/ExportOptions.plist`,
`signingStyle: automatic`), and automatic signing talks to the portal to refresh
provisioning profiles. With the portal offline that can fail, which would stop
new iOS betas for the length of the migration.

Everything needed to sign without the portal is already on this Mac and does not
expire until mid-2027:

| Asset | Expires |
| --- | --- |
| `Apple Distribution: VAHID HASHEMI (A53J987N2C)` | 2027-06-29 |
| `iOS Team Store Provisioning Profile: online.novaproxy.novaClient` | 2027-06-29 |
| `iOS Team Store Provisioning Profile: online.novaproxy.novaClient.NovaTunnel` | 2027-06-29 |
| `Developer ID Application` (macOS notarization) | 2027-02-01 |

Backed up on 2026-08-19 to `~/NovaSigning-backup-2026-08-19/profiles` (four
`.mobileprovision` files: the app and the tunnel extension, development and
store). The certificates themselves stay in the login keychain; exporting them
needs the keychain password, so that is a manual step if this Mac is ever
replaced.

If a build fails during the blackout, switch to manual signing for the duration:

1. In `ios/ExportOptions.plist`, set `signingStyle` to `manual` and add:

   ```xml
   <key>provisioningProfiles</key>
   <dict>
     <key>online.novaproxy.novaClient</key>
     <string>iOS Team Store Provisioning Profile: online.novaproxy.novaClient</string>
     <key>online.novaproxy.novaClient.NovaTunnel</key>
     <string>iOS Team Store Provisioning Profile: online.novaproxy.novaClient.NovaTunnel</string>
   </dict>
   <key>signingCertificate</key>
   <string>Apple Distribution</string>
   ```

2. In Xcode (Runner and NovaTunnel targets), turn off "Automatically manage
   signing" and pick those profiles.
3. Build and upload as usual (`flutter build ipa --release`, then
   `xcrun altool --upload-app ... --apiKey 4NF8HTUX29 --apiIssuer 048b417e-...`).
4. Revert both changes once the migration completes, so profile renewal goes
   back to being automatic.

Nothing here affects Android, Windows or macOS releases; those keep shipping
normally.

## After the migration completes

- Confirm the team name in App Store Connect reads Innovate Northtech Inc.
- Re-check the App Store listing: the seller/developer name should be the
  company, not the personal name.
- Then resubmit the App Store version. Address 4.3(a) explicitly in the review
  notes: what makes Nova distinct (its own panel/subscription ecosystem, the
  measuring core, the Iran-specific anti-censorship work), and that it is
  published by a registered company that operates the service.
- The App Store version to submit should be the current shipping build, not
  0.3.3.
