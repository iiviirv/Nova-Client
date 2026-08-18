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
codesign --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements -s "$ID" "${KCARGS[@]}" "$APP" 2>&1 | tail -1
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
hdiutil detach "/Volumes/Nova" 2>/dev/null
hdiutil create -volname "Nova" -srcfolder "$STAGE" -fs "HFS+" -format UDZO -ov "$DMG" 2>&1 | tail -2
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
cp -f "$DMG" "$STABLE_DMG"
cp -f "$ZIP" "$STABLE_ZIP"
cp -f "$DMG" "$LEGACY_DMG"
cp -f "$ZIP" "$LEGACY_ZIP"
echo "upload these to the release:"
echo "  $STABLE_DMG   (primary, universal)"
echo "  $STABLE_ZIP"
echo "  $LEGACY_DMG   (compat alias for links already shared)"
echo "  $LEGACY_ZIP"
echo "RELEASE_MACOS_DONE b$B"
