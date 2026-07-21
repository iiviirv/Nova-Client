#!/bin/zsh
# Build, sign, notarize, staple the macOS app and produce BOTH a zip and a DMG.
# Usage: ./tool/release_macos.sh <build-number>      e.g. ./tool/release_macos.sh 60
# Outputs in /tmp:  Nova-macOS-arm64-b<n>.zip  and  Nova-macOS-arm64-b<n>.dmg
# macOS-only: needs the Developer ID identity in the signing keychain and the
# App Store Connect notary key on disk. Runs locally, not in GitHub CI.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1
PROJ="$PWD"

B="${1:?usage: release_macos.sh <build-number>}"
ISSUER="048b417e-9426-428a-a694-f18b1384a7d0"
KEYID="4NF8HTUX29"
ID="Developer ID Application: the Nova team (A53J987N2C)"
KC=/tmp/nova-signing.keychain-db
KEY=~/.appstoreconnect/private_keys/AuthKey_$KEYID.p8
ZIP=/tmp/Nova-macOS-arm64-b$B.zip
DMG=/tmp/Nova-macOS-arm64-b$B.dmg

echo "############ build macOS ############"
flutter build macos --release 2>&1 | tail -5
APP="$PROJ/build/macos/Build/Products/Release/nova_client.app"
if [[ ! -d "$APP" ]]; then echo "!! macOS app not produced"; exit 1; fi
cp "$PROJ/assets/bin/sing-box-macos-arm64" "$APP/Contents/Resources/sing-box-macos-arm64"
echo "core bundled: $(ls -lh "$APP/Contents/Resources/sing-box-macos-arm64" | awk '{print $5}')"

echo "--- sign (Developer ID + hardened runtime, inside-out) ---"
security unlock-keychain -p novakc "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"') >/dev/null 2>&1
for fw in objective_c FlutterMacOS App; do
  codesign --force --options runtime --timestamp -s "$ID" --keychain "$KC" "$APP/Contents/Frameworks/$fw.framework" 2>&1 | tail -1
done
codesign --force --options runtime --timestamp -s "$ID" --keychain "$KC" "$APP/Contents/Resources/sing-box-macos-arm64" 2>&1 | tail -1
codesign --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements -s "$ID" --keychain "$KC" "$APP" 2>&1 | tail -1
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
codesign --force --timestamp -s "$ID" --keychain "$KC" "$DMG" 2>&1 | tail -1

echo "--- notarize DMG ---"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEYID" --issuer "$ISSUER" --wait 2>&1 | tail -6
xcrun stapler staple "$DMG" 2>&1 | tail -1
xcrun stapler validate "$DMG" 2>&1 | tail -1
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tail -3
ls -lh "$DMG" | awk '{print "macOS dmg:", $5}'
echo "RELEASE_MACOS_DONE b$B"
