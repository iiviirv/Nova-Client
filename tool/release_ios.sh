#!/bin/zsh
# Build the iOS app, upload it to App Store Connect, and put it in front of the
# testers: What to Test, the Public Beta group, and the beta review submission.
#
# Usage:  ./tool/release_ios.sh <build-number> ["what to test text"]
#         e.g. ./tool/release_ios.sh 117 "Fixes AmneziaWG 3 on iPhone."
#
# Why this exists. iOS was the only platform with no script and no workflow, so
# every release was a sequence someone had to remember. v1.20.16-beta is what
# happens when they do not: it shipped as "every platform" while the iPhone
# build was never made, so an AmneziaWG 3 fix reached Android, Windows and Linux
# and no iPhone at all. Nobody noticed until a user reported that AmneziaWG 3
# would not connect.
#
# macOS-only: needs Xcode, the signing identity, and the App Store Connect API
# key on disk. Runs locally, not in CI, for the same reason release_macos.sh
# does: the signing material is not in the repo.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

B="${1:?usage: release_ios.sh <build-number> [\"what to test\"]}"
NOTES="${2:-}"

APP_ID="6804490430"
ISSUER="048b417e-9426-428a-a694-f18b1384a7d0"
KEYID="4NF8HTUX29"
# The external group the public TestFlight link points at. An internal group
# needs nothing: it receives every build automatically, and asking for one is
# an error rather than a no-op ("Cannot add internal group to a build").
PUBLIC_GROUP="2bccd1fb-d182-47bc-abb9-50cd5f66a95c"

# The marketing version comes from the pubspec, so this cannot disagree with it.
NAME="$(grep -m1 '^version:' pubspec.yaml | sed 's/^version: *//' | cut -d+ -f1)"
[[ -n "$NAME" ]] || { echo "!! could not read version from pubspec.yaml"; exit 1; }

say() { printf '\n== %s\n' "$1" }

# The constants the app reports must match the pubspec, or the update check
# compares against a stale tag and offers an update the user already installed.
# That shipped once (v1.20.16-beta); the test exists precisely to stop it, so it
# runs here rather than relying on anyone to remember.
say "Checking the version constants agree with the pubspec"
flutter test test/version_consistency_test.dart 2>&1 | tail -3
grep -q "kNovaBuild = '$B'" lib/src/core/update/update_checker.dart || {
  echo "!! kNovaBuild is not '$B'. Bump update_checker.dart with the pubspec."
  exit 1
}

say "Building the App Store IPA ($NAME+$B)"
flutter build ipa --release \
  --build-name="$NAME" --build-number="$B" \
  --export-options-plist=ios/ExportOptions.plist 2>&1 | tail -4
IPA="$(ls build/ios/ipa/*.ipa 2>/dev/null | head -1)"
[[ -f "$IPA" ]] || { echo "!! no IPA was produced"; exit 1; }

say "Uploading to App Store Connect"
xcrun altool --upload-app --type ios -f "$IPA" \
  --apiKey "$KEYID" --apiIssuer "$ISSUER" 2>&1 | grep -E "UPLOAD|ERROR|Delivery UUID"

# Processing takes a few minutes, and everything below needs the build to exist.
say "Waiting for Apple to finish processing build $B"
BID=""
for i in {1..60}; do
  BID="$(tool/asc.sh "builds?filter[app]=$APP_ID&limit=8" 2>/dev/null \
    | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for x in d.get('data',[]):
    a=x['attributes']
    if a.get('version')=='$B' and a.get('processingState')=='VALID':
        print(x['id']); break
")"
  [[ -n "$BID" ]] && break
  sleep 30
done
[[ -n "$BID" ]] || {
  echo "!! build $B did not reach VALID. It may still be processing; the"
  echo "   remaining steps (What to Test, group, review) are not done."
  exit 1
}
echo "   build $B is VALID"

if [[ -n "$NOTES" ]]; then
  say "Setting What to Test"
  tool/asc.sh "builds/$BID/betaBuildLocalizations" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for l in d.get('data',[]):
    print(l['id'], l['attributes'].get('locale'))
" | while read -r lid locale; do
    # Apple pre-creates the localization, so this is a PATCH; a POST is a 409.
    tool/asc.sh "betaBuildLocalizations/$lid" PATCH \
      "{\"data\":{\"type\":\"betaBuildLocalizations\",\"id\":\"$lid\",\"attributes\":{\"whatsNew\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTES")}}}" \
      >/dev/null && echo "   $locale set"
  done
fi

say "Adding to the Public Beta group"
tool/asc.sh "betaGroups/$PUBLIC_GROUP/relationships/builds" POST \
  "{\"data\":[{\"type\":\"builds\",\"id\":\"$BID\"}]}" >/dev/null \
  && echo "   added"

say "Submitting for beta review"
tool/asc.sh "betaAppReviewSubmissions" POST \
  "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$BID\"}}}}}" \
  >/dev/null && echo "   submitted"

# Prove it from Apple's side rather than trusting the calls above, the same way
# release_macos.sh re-checks the download links instead of the upload's exit code.
say "Verifying from App Store Connect"
tool/asc.sh "betaGroups/$PUBLIC_GROUP/builds?limit=10" | python3 -c "
import json,sys
d=json.load(sys.stdin)
vs=sorted((x['attributes']['version'] for x in d.get('data',[])), key=int, reverse=True)
print('   Public Beta serves:', ', '.join(vs[:4]))
print('   build $B present:', '$B' in vs)
"

echo "RELEASE_IOS_DONE b$B"
