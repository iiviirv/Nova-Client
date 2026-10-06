# Android release signing (fixes the "unsafe app" sideload warning)

Debug-signed APKs are treated by Android/Play Protect as untrusted development
builds and trip the "this app is not safe, install anyway" warning on sideload.
The fix is signing every released APK with a permanent Nova upload key.

`android/app/build.gradle.kts` uses a real release key when
`android/key.properties` exists. When it does not, a release build is **refused**
rather than debug-signed, unless you ask for debug signing by name with
`-PnovaAllowDebugSigning=true` (or the `ORG_GRADLE_PROJECT_novaAllowDebugSigning`
environment variable). Debug builds and `flutter run` are unaffected; the check
only looks at an actual release assembly.

So the whole job is: make `key.properties` (and the keystore) available at build
time. Both are gitignored (`android/.gitignore`) and must never be committed.

## There is exactly one live key

`CN=Innovate Northtech Inc., OU=Nova, O=Innovate Northtech Inc., L=Keswick,
ST=Ontario, C=CA`. It lives only in the GitHub secrets below, and CI signs every
published APK with it.

A second, retired keystore exists on the release Mac at
`~/.nova-keys/nova-release.jks`, holding `CN=Nova Proxy, O=Nova Proxy Group,
C=US`. **It signs nothing that ships.** Its passwords are beside it in
`~/.nova-keys/key.properties.retired-nova-proxy`. Keep both only as a record of
what old APKs were signed with.

On 2026-10-06 that retired key was still wired up as `android/key.properties` on
the release Mac, so local release builds were signed with it. They install on a
clean device and look fine, but Android refuses them as an update over a
published build because the signature does not match. Four such APKs were built
and handed over as release artifacts before anyone noticed. That is the reason
for the gate above: a local build must never be mistakable for a shippable one.

## The keystore
Generated once (kept by Vahid; losing it or its password means existing users can
never be updated):

    keytool -genkeypair -v -keystore ~/nova-release.jks -keyalg RSA -keysize 2048 \
      -validity 10000 -alias nova \
      -dname "CN=Innovate Northtech Inc., OU=Nova, O=Innovate Northtech Inc., L=Keswick, ST=Ontario, C=CA"

Alias: `nova`. Store password == key password (Return reused it at prompt).

## CI (the shipped APKs), `.github/workflows/build-apk.yml`
The "Set up release signing" step decodes the keystore and writes `key.properties`
before the build, from four repo secrets. Without them the release build now fails
instead of debug-signing, so a tag build that has lost its secrets stops rather
than publishing an APK that no existing user can install. Pull requests, which
GitHub never gives secrets to, opt into debug signing explicitly in the build
step.

Add these in the CI repo's GitHub Settings -> Secrets and variables -> Actions
(the same place `IRNOVA_TOKEN` lives):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 < ~/nova-release.jks` output (whole thing) |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_PASSWORD` | same password (key password) |
| `ANDROID_KEY_ALIAS` | `nova` |

## Local signed builds

Prefer not to. CI builds and signs every published APK, and a locally signed one
is an opportunity to ship the wrong signature. Download the artifact from the
release instead.

If you genuinely need one, point `android/key.properties` at the **live**
keystore, never the retired one, and delete the file again afterwards:

    storeFile=/absolute/path/to/the/live/nova-release.jks
    storePassword=<password>
    keyAlias=nova
    keyPassword=<password>

Check what you produced before giving it to anyone:

    apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk

It must say `CN=Innovate Northtech Inc.`. Anything else, including
`CN=Nova Proxy` or `CN=Android Debug`, cannot update an installed Nova.

For a throwaway build where the signature does not matter:

    flutter build apk --release -PnovaAllowDebugSigning=true

That APK is debug-signed. Do not hand it to a tester.

## What this does and doesn't fix
- Fixes: the "untrusted / debug build" distrust; enables consistent updates; a
  prerequisite for any store. Big reduction in the scary warning.
- Does NOT remove: Android's one-time "allow installs from this source" prompt,
  inherent to direct APK sideloading. For a warning-free install without publishing
  a developer address, distribute via the F-Droid / IzzyOnDroid repo (users install
  through the trusted F-Droid client). Google Play would remove it entirely but
  requires an organization account with a public address.
