# Direct download links, and app-store-free auto-updates

## Permanent direct links

These never change and always resolve to the newest release, so they can be
pinned in Telegram, printed, or handed out anywhere:

| Platform | Link |
| --- | --- |
| Android (all devices) | `https://github.com/IRNova/Nova-Client/releases/latest/download/nova-client.apk` |
| Android (smaller, 64-bit ARM) | `.../releases/latest/download/nova-client-arm64-v8a.apk` |
| Android (smaller, 32-bit ARM) | `.../releases/latest/download/nova-client-armeabi-v7a.apk` |
| Windows | `.../releases/latest/download/Nova-Windows.zip` |
| macOS | `.../releases/latest/download/Nova-macOS-arm64.dmg` |

The per-ABI Android builds are about 42 MB against 121 MB for the universal one.
Most modern phones want `arm64-v8a`. If someone is unsure, the universal
`nova-client.apk` always works.

**These only keep working if asset names stay stable across releases.** See
`irnova-site/docs/download-links.md`; a build number in the macOS filename is
what made that link 404 for weeks.

## Auto-updates without any store

A direct link gets someone the app once. What F-Droid really provides is
*notification when a new version exists*. Three ways to get that:

### 1. Obtainium (works today, nothing to set up)

[Obtainium](https://github.com/ImranR98/Obtainium) tracks an app's GitHub
releases and notifies on a new version, with a one tap update. No account, no
store, no approval process, and it is well known among users in censored
regions. Users add this URL:

    https://github.com/IRNova/Nova-Client

Because the release carries several APKs, tell users to set the APK filter to
whichever they want, for example `nova-client-arm64-v8a\.apk` for the small
64-bit build, or `nova-client\.apk$` for the universal one. Without a filter
Obtainium asks which asset to use on the first install.

This is the recommended answer today, since it needs nothing from us.

### 2. IzzyOnDroid (a real F-Droid style repo)

Users add one repo URL to the F-Droid client and Nova appears alongside their
other apps with normal update handling. This is the closest thing to "we are on
F-Droid". Status and the paste-ready request are in
`docs/izzyondroid-submission.md`. It needs their maintainer to accept the app,
so it is not instant.

### 3. The app's own update check

Nova already checks `api.github.com/repos/IRNova/Nova-Client/releases/latest` on
launch and shows a banner when a newer tag exists (see
`lib/src/core/update/update_checker.dart`). That covers people who already have
the app and open it; it does not help someone who never opens it.

## Deliberately not F-Droid's main repo

F-Droid proper requires reproducible builds, which would mean building the
sing-box and Xray cores reproducibly on their infrastructure. That is a large
piece of work and is out of scope; IzzyOnDroid lists the upstream-signed APK
instead and does not require it.
