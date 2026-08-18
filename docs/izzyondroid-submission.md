# IzzyOnDroid submission (F-Droid-compatible repo)

IzzyOnDroid lists prebuilt APKs from GitHub Releases. It is the address-free
distribution channel: unlike Google Play, it does not publish a developer's
physical address, and unlike a bare APK download it reduces the "unsafe app"
friction because users add a trusted repo once.

## BLOCKER: the default branch is stale

IzzyOnDroid (and GitHub's own license detection) read the **default branch**,
which is `main`. Today `main` still carries:

- the **old MIT LICENSE** (GitHub reports the repo as MIT), while the current
  license is **GPL-3.0** (required, since the app links GPL cores);
- **no `fastlane/metadata/`** directory, which is where IzzyOnDroid picks up the
  title, descriptions, changelogs and icon.

Both exist only on the release branch. As of this writing the release branch is
**76 commits ahead** of `main`, and `main` has just **1** commit not in it
(`867895a CI: publish Windows to IRNova releases + CHANGELOG-driven notes`).

**Decision needed (Vahid):** merge the release branch into `main` (or make it the
default branch) before submitting. Submitting against the current `main` would
list Nova as MIT with no store metadata.

## Checklist

| Requirement | State |
| --- | --- |
| Public repo | Yes, `github.com/iiviirv/Nova-Client` |
| FOSS license in repo | GPL-3.0 present, but **only on the release branch** |
| APK on a GitHub Release | Latest release is stale (`v0.2.0-b59`; current build is 82) |
| Release APK signed with a stable key | Yes, CI signs with the permanent upload key |
| `fastlane/metadata/android/en-US/` | Present (title, short + full description, icon, changelog), **release branch only** |
| No proprietary blobs / trackers | Cores are built from pinned FOSS sources in CI |
| versionCode increases per release | Yes, driven by `pubspec.yaml` (`0.3.3+82`) |

## Steps once `main` is current

1. **Cut a GitHub Release** for the current build with the APK attached
   (`nova-client.apk` plus the per-ABI APKs the workflow already stages). The
   tag should match the version, e.g. `v1.10.0-beta` / build 82.
2. **File the RFP (Request For Packaging)** at
   `https://gitlab.com/IzzyOnDroid/repo/-/issues` using the template below.
   This needs Vahid's GitLab account; it is an outward-facing post, so it is
   his to submit.
3. IzzyOnDroid's maintainer reviews, adds the app to their updater config, and
   the app appears in the IzzyOnDroid repo (usually within days).

## RFP text (paste into the GitLab issue)

Title:

    RFP: Nova - anti-censorship proxy client

Body:

    App name: Nova
    Source: https://github.com/iiviirv/Nova-Client
    License: GPL-3.0-or-later
    Upstream releases: GitHub Releases, APK attached to each release
    Package id: online.novaproxy.nova_client

    Description:
    Nova is an open-source client for reaching the open internet on restricted
    networks. Users bring their own configuration or subscription and connect
    through infrastructure they control. It bundles the sing-box and Xray cores
    and supports VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard,
    AmneziaWG, NaiveProxy and mieru.

    Metadata: fastlane/metadata/android/en-US/ (title, short and full
    description, icon, changelogs) is in the repository.

    Signing: release APKs are signed in CI with a permanent upload key, so the
    signature is stable across releases.

    Anti-features: none known. The app ships no ads, no analytics and no
    tracking. Network access is the point of the app (it is a proxy client) and
    it only contacts servers the user configures.

## Note on reproducible builds

IzzyOnDroid lists the upstream-signed APK; it does not require reproducible
builds. F-Droid's main repo does, which would mean building the sing-box/Xray
cores reproducibly on their infrastructure. That is a much bigger lift and is
deliberately out of scope here.
