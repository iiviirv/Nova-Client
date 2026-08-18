# IzzyOnDroid submission (F-Droid-compatible repo)

IzzyOnDroid lists prebuilt APKs from GitHub Releases. It is the address-free
distribution channel: unlike Google Play it does not publish a developer's
physical address, and unlike a bare APK download it reduces the "unsafe app"
friction because users add a trusted repo once.

## Where to submit (this moved)

**Not GitLab.** The old GitLab tracker is archived. App-inclusion requests now
go to the **repodata** tracker on Codeberg:

    https://codeberg.org/IzzyOnDroid/repodata/issues/new/choose
    -> choose "App Inclusion Request"

This needs a **Codeberg** account (free). Creating the account and posting the
issue are Vahid's to do; the content below is ready to paste.

Inclusion policy: https://izzyondroid.org/docs/general/AppInclusionPolicy/

## Readiness

| Requirement | State |
| --- | --- |
| Public source repo | Yes, `github.com/iiviirv/Nova-Client` |
| FOSS license | GPL-3.0, and `main` now reports it correctly |
| Fastlane folder in the repo | Yes, `fastlane/metadata/android/en-US/` on `main` |
| APK on a GitHub Release | v1.11.0-beta (build 83), published by CI |
| Stable signing key | Yes, CI signs every release with the permanent upload key |
| Not already listed | Confirm at https://apt.izzysoft.de/fdroid/ before posting |

## Form answers (paste into the template fields)

**Title**

    [AppRequest] Nova

**Guidelines checkboxes:** tick "I am the developer of the app", "complies with
the App Inclusion Policy", "not already listed" and "Fastlane folder available".

**Link to the source code**

    https://github.com/iiviirv/Nova-Client

**Link to app in another app store:** leave empty (not on Play or F-Droid).

**License used**

    GPL-3.0-or-later

**Categories:** `Connectivity`, `Internet`, `Security`

**Summary**

    An anti-censorship proxy client that connects through servers you control,
    with a clean-IP scanner and one-tap self-hosting.

**Description**

    Nova is a client for reaching the open internet on restricted networks. You
    bring your own configuration or subscription and connect through
    infrastructure you control, so there is no shared middleman.

    It bundles the sing-box and Xray cores and supports VLESS (including
    Reality and xhttp), VMess, Trojan, Shadowsocks, Hysteria2, WireGuard,
    AmneziaWG, NaiveProxy and mieru.

    Other features: a scanner that finds working clean IPs when the usual
    endpoints are blocked, an SNI-block bypass for networks that filter on the
    server name, per-server latency measured through the tunnel, a status
    notification with one-tap disconnect, a home-screen widget, and an English
    and Farsi interface with full right-to-left support.

    No ads, no analytics, no tracking. The app only contacts the servers the
    user configures.

**Build instructions**

    # Prerequisites: JDK 17, Go 1.24.7, Android SDK + NDK 28.0.13004108,
    # Flutter (stable channel).

    git clone https://github.com/iiviirv/Nova-Client
    cd Nova-Client

    # 1. Build the native core. This is sing-box v1.13.13 with the AmneziaWG
    #    patch and the Xray core folded in, compiled to an Android AAR via
    #    gomobile. The script verifies the patches applied and fails otherwise.
    bash tool/core/build-combined-core.sh "$PWD/android/app/libs/libbox.aar"

    # 2. Build the APK.
    flutter pub get
    flutter build apk --release

    # Split-per-ABI (what the release publishes alongside the universal APK):
    flutter build apk --release --split-per-abi

    # Output: build/app/outputs/flutter-apk/

**AI Tools Usage — Assistance Level**

    Substantial – Used throughout development

**"AI" Tool(s)**

    Claude (Claude Code)

**What did the tools help with?**

    Used throughout as a coding assistant: implementing protocol support and
    the native Android/iOS tunnel plumbing, UI work, debugging (for example a
    routing loop in the two-core data path), writing tests, and documentation.
    Architecture decisions, the security model and all release decisions were
    made by the developer.

**AI Accountability:** tick both boxes only if true for you. For this project
both hold: outputs were reviewed and edited, and changes were manually tested
(the test suite plus on-device and emulator verification).

**Further Notices**

    I am the developer of the app.

    The bundled cores (sing-box, Xray) are FOSS and are built from pinned
    sources by the release workflow, not shipped as opaque prebuilt blobs. The
    build is reproducible from the repository using the instructions above.

    Anti-features: none known. No ads, analytics or tracking. Network access is
    the purpose of the app (it is a proxy client) and it only contacts servers
    the user configures.

## Note on reproducible builds

IzzyOnDroid lists the upstream-signed APK and does not require reproducible
builds (they run an RB transparency log separately, opt-in). F-Droid's main repo
does require them, which would mean building the sing-box and Xray cores
reproducibly on their infrastructure. That is a much bigger lift and is
deliberately out of scope here.

## A caution about Codeberg's terms

Codeberg recently restricted LLM-generated content on the platform. The template
itself asks for an AI-usage disclosure rather than forbidding AI use, so
disclosing honestly (as above) is the right move. Post in your own words and
review the text before submitting rather than pasting it unread.
