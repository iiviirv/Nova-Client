#!/bin/zsh
# Build, sign, notarize, staple the macOS app and produce BOTH a zip and a DMG.
# Usage: ./tool/release_macos.sh <build-number>      e.g. ./tool/release_macos.sh 60
# Outputs in /tmp: Nova-macOS.dmg and Nova-macOS.zip (universal: Intel + Apple
# Silicon), plus Nova-macOS-arm64.* compat aliases.
# macOS-only: needs the Developer ID identity in the signing keychain and the
# App Store Connect notary key on disk. Runs locally, not in GitHub CI.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
PROJ="$PWD"

B="${1:?usage: release_macos.sh <build-number>}"
ISSUER="048b417e-9426-428a-a694-f18b1384a7d0"
KEYID="4NF8HTUX29"
# The signing identity, by certificate SHA-1 rather than by name. A hash is
# what codesign matches most reliably, it survives the certificate's common name
# not being what a script expects, and it is not a person's name in the repo.
# `security find-identity -v -p codesigning` lists it. Override with
# NOVA_CODESIGN_ID for a different Mac or a renewed certificate.
ID="${NOVA_CODESIGN_ID:-86D5AC8632E81F27B2CAFA6C843AF1114E16A7A9}"
# Optional dedicated signing keychain (password novakc). When it is absent (it
# lives in /tmp and does not survive a reboot) the login keychain, where the
# Developer ID identity normally lives, is used as-is.
KC=/tmp/nova-signing.keychain-db
KCARGS=()
if [[ -f "$KC" ]]; then
  security unlock-keychain -p novakc "$KC"
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"') >/dev/null 2>&1
  KCARGS=(--keychain "$KC")
fi
KEY=~/.appstoreconnect/private_keys/AuthKey_$KEYID.p8
ZIP=/tmp/Nova-macOS-arm64-b$B.zip
DMG=/tmp/Nova-macOS-arm64-b$B.dmg

echo "############ build macOS ############"
flutter build macos --release 2>&1 | tail -5
APP="$PROJ/build/macos/Build/Products/Release/nova_client.app"
if [[ ! -d "$APP" ]]; then echo "!! macOS app not produced"; exit 1; fi
# Bundle the cores for BOTH architectures. The Flutter app bundle is universal
# (x86_64 + arm64) and the app resolves its core by the architecture it is
# actually running on, so shipping only the arm64 core meant an Intel Mac
# launched the app and then had nothing to run. Missing arch is fatal: a DMG
# that half works on Intel is worse than a build failure here.
for a in arm64 amd64; do
  src="$PROJ/assets/bin/sing-box-macos-$a"
  if [[ ! -f "$src" ]]; then
    echo "!! missing $src (build it: tool/core/build-desktop.sh darwin)"; exit 1
  fi
  cp "$src" "$APP/Contents/Resources/sing-box-macos-$a"
  echo "core bundled ($a): $(ls -lh "$APP/Contents/Resources/sing-box-macos-$a" | awk '{print $5}')"
done
# Second core, Xray, for xhttp exits. Best-effort: an older tree without it just
# ships without xhttp support (the app says so at connect time).
for a in arm64 amd64; do
  if [[ -f "$PROJ/assets/bin/xray-macos-$a" ]]; then
    cp "$PROJ/assets/bin/xray-macos-$a" "$APP/Contents/Resources/xray-macos-$a"
    echo "xray core bundled ($a): $(ls -lh "$APP/Contents/Resources/xray-macos-$a" | awk '{print $5}')"
  fi
done

echo "--- sign (Developer ID + hardened runtime, inside-out) ---"
# Sign EVERY nested framework/dylib, not a hardcoded list: a plugin framework
# (e.g. flutter_secure_storage_macos) left with its build-time signature fails
# notarization ("not signed with a valid Developer ID certificate").
for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do
  codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$dylib" 2>&1 | tail -1
done
for fw in "$APP"/Contents/Frameworks/*.framework(N); do
  codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$fw" 2>&1 | tail -1
done
# Every bundled core must be signed, or notarization rejects the app.
for core in "$APP"/Contents/Resources/sing-box-macos-* "$APP"/Contents/Resources/xray-macos-*; do
  [[ -f "$core" ]] || continue
  codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$core" 2>&1 | tail -1
done
# The tunnel's system extension, signed inside out and with its OWN
# entitlements: it carries the packet-tunnel entitlement and the app group, and
# re-signing it with the app's entitlements (or with none) would strip those and
# leave macOS refusing to activate it. Its embedded provisioning profile is what
# authorises them, and Xcode put that inside during the build.
# Named for its bundle identifier, because that is how macOS finds it.
SYSEX="$APP/Contents/Library/SystemExtensions/online.novaproxy.novaClient.NovaTunnel.systemextension"
if [[ -d "$SYSEX" ]]; then
  # A versioned framework is signed at Versions/A, not at the wrapper. Signing
  # only the wrapper leaves the real binary carrying its build-time signature,
  # and notarization rejects that: "not signed with a valid Developer ID
  # certificate" and "the signature does not include a secure timestamp",
  # pointing at Novacore.framework/Versions/A/Novacore.
  # A statically-linked extension has no Frameworks directory at all, which is
  # the normal case here: the core is linked into the extension's binary.
  for fw in "$SYSEX"/Contents/Frameworks/*.framework(N); do
    [[ -d "$fw/Versions/A" ]] && codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$fw/Versions/A" 2>&1 | tail -1
    codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$fw" 2>&1 | tail -1
  done
  for dylib in "$SYSEX"/Contents/Frameworks/*.dylib(N); do
    codesign --force --options runtime --timestamp -s "$ID" "${KCARGS[@]}" "$dylib" 2>&1 | tail -1
  done
  codesign --force --options runtime --timestamp \
    --entitlements macos/NovaTunnel/NovaTunnel.entitlements \
    -s "$ID" "${KCARGS[@]}" "$SYSEX" 2>&1 | tail -1
  [[ -f "$SYSEX/Contents/embedded.provisionprofile" ]] \
    || { echo "!! the system extension has no embedded provisioning profile, so macOS will refuse it"; exit 1; }
  echo "system extension signed: $(du -sh "$SYSEX" | awk '{print $1}')"
else
  echo "!! no system extension in the app bundle; the Mac will fall back to the admin prompt"
fi
codesign --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements -s "$ID" "${KCARGS[@]}" "$APP" 2>&1 | tail -1
# The app's own profile authorises installing that extension. Without it the
# app launches and every activation request fails with "invalid signature".
[[ -f "$APP/Contents/embedded.provisionprofile" ]] \
  || { echo "!! the app has no embedded provisioning profile; system-extension install will be refused"; exit 1; }
codesign --verify --deep --strict "$APP" 2>&1 | tail -2 && echo "signature valid"

echo "--- notarize app ---"
rm -f /tmp/nova$B-notarize.zip
ditto -c -k --keepParent "$APP" /tmp/nova$B-notarize.zip
xcrun notarytool submit /tmp/nova$B-notarize.zip --key "$KEY" --key-id "$KEYID" --issuer "$ISSUER" --wait 2>&1 | tail -6

echo "--- staple app + make zip ---"
xcrun stapler staple "$APP" 2>&1 | tail -1
spctl -a -vv "$APP" 2>&1 | head -3
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ls -lh "$ZIP" | awk '{print "macOS zip:", $5}'

echo "############ build DMG ############"
STAGE=/tmp/nova$B-dmgstage
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# -fs "HFS+" is required; the APFS default fails with "image not recognized"
# The create races the volume it just detached and fails with "Resource
# temporarily unavailable" often enough to have bitten three releases, so give
# the volume time to settle and retry rather than treating one attempt as the
# answer.
hdiutil detach "/Volumes/Nova" 2>/dev/null
sync; sleep 3
for try in 1 2 3; do
  hdiutil create -volname "Nova" -srcfolder "$STAGE" -fs "HFS+" -format UDZO -ov "$DMG" 2>&1 | tail -2
  [[ -f "$DMG" ]] && break
  echo "-- hdiutil attempt $try produced no image, settling and retrying"
  hdiutil detach "/Volumes/Nova" 2>/dev/null; sync; sleep 8
done
# Stop here if there is still no image. Carrying on used to exit 0 and then
# print "upload these" pointing at /tmp/Nova-macOS.dmg, which still held the
# PREVIOUS build: a silent wrong-artifact rather than a failure. Fail loudly.
if [[ ! -f "$DMG" ]]; then
  echo "!! hdiutil could not create $DMG after 3 attempts."
  echo "!! Stopping BEFORE the stable-name copies: /tmp/Nova-macOS.dmg still"
  echo "!! holds an older build and must not be uploaded as this one."
  exit 1
fi
codesign --force --timestamp -s "$ID" "${KCARGS[@]}" "$DMG" 2>&1 | tail -1

echo "--- notarize DMG ---"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEYID" --issuer "$ISSUER" --wait 2>&1 | tail -6
xcrun stapler staple "$DMG" 2>&1 | tail -1
xcrun stapler validate "$DMG" 2>&1 | tail -1
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tail -3
ls -lh "$DMG" | awk '{print "macOS dmg:", $5}'

# Also emit build-number-free copies. The website links to
# releases/latest/download/Nova-macOS-arm64.dmg, which only resolves if the
# ASSET name is stable across releases; uploading only the "-b<n>" name is what
# made that link 404. The release tag already carries the version, so the stable
# name loses nothing. Upload these two to the release.
#
# The build is universal (Intel + Apple Silicon, app and cores), so the primary
# name no longer says arm64: calling it that told Intel users it was not for
# them. The old arm64 names are still emitted so links already shared in
# Telegram and elsewhere keep resolving; they can be dropped after a release or
# two.
STABLE_DMG=/tmp/Nova-macOS.dmg
STABLE_ZIP=/tmp/Nova-macOS.zip
LEGACY_DMG=/tmp/Nova-macOS-arm64.dmg
LEGACY_ZIP=/tmp/Nova-macOS-arm64.zip
# Every copy is checked. A failed copy leaves the previous build's file sitting
# under the exact name the next line tells you to upload, which is how a stale
# DMG almost shipped as a new release.
for pair in "$DMG:$STABLE_DMG" "$ZIP:$STABLE_ZIP" "$DMG:$LEGACY_DMG" "$ZIP:$LEGACY_ZIP"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  if ! cp -f "$src" "$dst"; then
    echo "!! could not copy $src -> $dst; $dst may hold an older build. Not uploading."
    exit 1
  fi
done
# Prove the shipping names are this build, not leftovers from a previous one.
for f in "$STABLE_DMG" "$LEGACY_DMG"; do
  if ! cmp -s "$DMG" "$f"; then echo "!! $f does not match $DMG"; exit 1; fi
done
for f in "$STABLE_ZIP" "$LEGACY_ZIP"; do
  if ! cmp -s "$ZIP" "$f"; then echo "!! $f does not match $ZIP"; exit 1; fi
done
echo "verified: all four upload names are build $B"

# ---- publish ----
#
# The upload used to be a separate command run by hand, which raced CI: the
# release only exists once the Android and Windows jobs have created it, and
# uploading before that put the macOS files on one repo and not the other. The
# website links to releases/latest/download/, so a release that exists without
# them serves a 404 for every Mac user until someone notices.
#
# So the script waits for the release to exist and then uploads to both repos
# itself. Set NOVA_NO_UPLOAD=1 to build only.
TAG="${NOVA_TAG:-$(git -C "$PROJ" describe --tags --abbrev=0 2>/dev/null)}"
if [[ -n "${NOVA_NO_UPLOAD:-}" ]]; then
  echo "built only (NOVA_NO_UPLOAD set). Files: $STABLE_DMG $STABLE_ZIP"
  echo "RELEASE_MACOS_DONE b$B"
# iOS is a separate script and a separate store, and it is the one that gets
# forgotten: v1.20.16-beta shipped as "every platform" with no iPhone build at
# all, so a fix reached Android, Windows and Linux and no iPhone. Say so here,
# where whoever cut the release is looking.
echo "-- iOS is NOT part of this. Run: ./tool/release_ios.sh $B \"what to test\""
  exit 0
fi
if [[ -z "$TAG" ]]; then
  echo "!! no tag found; push the release tag first, or set NOVA_TAG"
  exit 1
fi
echo "############ publish to $TAG ############"

REPOS=(IRNova/Nova-Client iiviirv/Nova-Client)

# Wait for CI to FINISH, not merely for the release to appear.
#
# The Windows and Android jobs both create the release, so it exists as soon as
# the first of them finishes. Waiting on that meant uploading while the Android
# job was still building and then declaring the release incomplete, which is
# exactly what happened on 1.19.0: macOS and Windows were there, the universal
# APK 404ed, and the verification below caught it.
#
# 30 minutes is well past a normal run and still bounded, so a failed CI stops
# this rather than hanging for ever.
echo "-- waiting for CI on $TAG"
ok=""
for _ in {1..90}; do
  states=$(gh run list --repo iiviirv/Nova-Client --limit 6 \
             --json headBranch,status -q \
             "[.[] | select(.headBranch==\"$TAG\") | .status] | join(\",\")")
  if [[ -n "$states" && "$states" != *queued* && "$states" != *in_progress* ]]; then
    ok=1; break
  fi
  sleep 20
done
if [[ -z "$ok" ]]; then
  echo "!! CI for $TAG did not finish in time; nothing uploaded."
  exit 1
fi
for r in "${REPOS[@]}"; do
  if ! gh release view "$TAG" --repo "$r" >/dev/null 2>&1; then
    echo "!! $TAG has no release on $r. CI probably failed; nothing uploaded there."
    exit 1
  fi
done

for r in "${REPOS[@]}"; do
  echo "-- uploading to $r"
  gh release upload "$TAG" "$STABLE_DMG" "$STABLE_ZIP" "$LEGACY_DMG" "$LEGACY_ZIP" \
    --repo "$r" --clobber || { echo "!! upload to $r failed"; exit 1; }
done

# Prove it from the outside, the way a user reaches it, rather than trusting the
# upload's exit code. This is the check that would have caught the release where
# one repo had the macOS files and the other did not.
echo "-- verifying the links the website uses"
fail=0
for f in Nova-macOS.dmg nova-client.apk Nova-Windows.zip; do
  code=$(curl -sIL -o /dev/null -w '%{http_code}' \
    "https://github.com/IRNova/Nova-Client/releases/latest/download/$f")
  printf '   %-22s %s\n' "$f" "$code"
  [[ "$code" == "200" ]] || fail=1
done
if [[ "$fail" != "0" ]]; then
  echo "!! a download link is not serving; the release is incomplete"
  exit 1
fi
echo "RELEASE_MACOS_DONE b$B"
