# Android release signing (fixes the "unsafe app" sideload warning)

Debug-signed APKs are treated by Android/Play Protect as untrusted development
builds and trip the "this app is not safe, install anyway" warning on sideload.
The fix is signing every released APK with a permanent Nova upload key.

`android/app/build.gradle.kts` already uses a real release key when
`android/key.properties` exists, and falls back to the debug key when it doesn't.
So the whole job is: make `key.properties` (and the keystore) available at build
time. Both are gitignored (`android/.gitignore`) and must never be committed.

## The keystore
Generated once (kept by Vahid; losing it or its password means existing users can
never be updated):

    keytool -genkeypair -v -keystore ~/nova-release.jks -keyalg RSA -keysize 2048 \
      -validity 10000 -alias nova \
      -dname "CN=Innovate Northtech Inc., OU=Nova, O=Innovate Northtech Inc., L=Keswick, ST=Ontario, C=CA"

Alias: `nova`. Store password == key password (Return reused it at prompt).

## CI (the shipped APKs) — `.github/workflows/build-apk.yml`
The "Set up release signing" step decodes the keystore and writes `key.properties`
before the build, from four repo secrets. Without them the build still runs but is
debug-signed (the fallback), so a release MUST have the secrets set.

Add these in the CI repo's GitHub Settings -> Secrets and variables -> Actions
(the same place `IRNOVA_TOKEN` lives):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 < ~/nova-release.jks` output (whole thing) |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_PASSWORD` | same password (key password) |
| `ANDROID_KEY_ALIAS` | `nova` |

## Local signed builds (optional)
Create `android/key.properties` (gitignored) with an absolute keystore path:

    storeFile=/Users/vahidhashemi/nova-release.jks
    storePassword=<your password>
    keyAlias=nova
    keyPassword=<your password>

Then `flutter build apk --release` produces a release-signed APK.

## What this does and doesn't fix
- Fixes: the "untrusted / debug build" distrust; enables consistent updates; a
  prerequisite for any store. Big reduction in the scary warning.
- Does NOT remove: Android's one-time "allow installs from this source" prompt,
  inherent to direct APK sideloading. For a warning-free install without publishing
  a developer address, distribute via the F-Droid / IzzyOnDroid repo (users install
  through the trusted F-Droid client). Google Play would remove it entirely but
  requires an organization account with a public address.
