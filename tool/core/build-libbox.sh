#!/usr/bin/env bash
# Build Nova's sing-box core (libbox.aar) with AmneziaWG.
#
# Stock sing-box has no AmneziaWG, so a core built from it takes the AmneziaWG
# endpoint the Dart layer emits and does nothing visible with it. This script
# builds the pinned upstream tag, applies the pinned patch, and refuses to hand
# back an AAR whose native libraries do not actually contain the protocol.
#
# Everything it depends on is pinned by value, not by "latest": the upstream
# commit, the patch's SHA-256, the NDK version, and the AmneziaWG module version
# (inside the patch's go.mod / go.sum). See docs/core-amneziawg.md.
#
# Usage:  tool/core/build-libbox.sh [output-path]
# Needs:  go, JDK 17, the Android SDK with the pinned NDK, git, unzip, shasum.

set -euo pipefail

SINGBOX_TAG="v1.13.13"
SINGBOX_COMMIT="78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba"
PATCH_SHA256="067aa9151015bd9687ad838285097f3b68e7dcd68ef214b2a5069d5bedac817b"
NOVAFRAG_PATCH_SHA256="3168ae867e65ef57689aeb4734ff488920f1c333e42ac8b506e25111893ac92c"
NDK_VERSION="${NDK_VERSION:-28.0.13004108}"
# Every ABI the APK can run on. An ABI the app installs on with no core in it
# is an app that connects to nothing, which is the defect this whole change
# exists to remove, so this list and the APK's ABI list move together. Each
# extra ABI costs about 50 MB of AAR.
PLATFORMS="${PLATFORMS:-android/arm64,android/arm,android/amd64}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patch_file="$repo_root/tool/core/amneziawg.patch"
output="${1:-$repo_root/android/app/libs/libbox.aar}"

say() { printf '\n== %s\n' "$1"; }

say "Checking the patch is the pinned one"
actual="$(shasum -a 256 "$patch_file" | cut -d' ' -f1)"
if [ "$actual" != "$PATCH_SHA256" ]; then
  echo "patch SHA-256 mismatch" >&2
  echo "  expected $PATCH_SHA256" >&2
  echo "  actual   $actual" >&2
  echo "If the patch was changed on purpose, update PATCH_SHA256 here and the" >&2
  echo "record in docs/core-amneziawg.md in the same commit." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Cloning sing-box $SINGBOX_TAG"
git clone --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box "$work/sing-box"
cd "$work/sing-box"
head="$(git rev-parse HEAD)"
if [ "$head" != "$SINGBOX_COMMIT" ]; then
  echo "upstream tag $SINGBOX_TAG now points at $head, not $SINGBOX_COMMIT" >&2
  echo "A moved tag is a supply-chain event, not a build failure. Stop and look." >&2
  exit 1
fi

say "Applying the AmneziaWG patch"
git apply --verbose "$patch_file"

novafrag_file="$repo_root/tool/core/novafrag.patch"
actual_nf="$(shasum -a 256 "$novafrag_file" | cut -d' ' -f1)"
if [ "$actual_nf" != "$NOVAFRAG_PATCH_SHA256" ]; then
  echo "novafrag patch SHA-256 mismatch" >&2
  echo "  expected $NOVAFRAG_PATCH_SHA256" >&2
  echo "  actual   $actual_nf" >&2
  exit 1
fi
say "Applying the nova_fragment patch (exact TLS fragmentation)"
git apply --verbose "$novafrag_file"

say "Proving the patched source builds an AmneziaWG endpoint"
# The same check the app makes at runtime, run here against the host build: a
# core without AmneziaWG fails this, a stock core cannot even decode the config.
go run -tags "with_gvisor,with_quic,with_wireguard,with_awg,with_utls,with_clash_api" ./cmd/internal/awg_probe

say "Installing the pinned gomobile"
go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.12
export PATH="$PATH:$(go env GOPATH)/bin"

if [ -z "${ANDROID_HOME:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}"
export NDK="$ANDROID_NDK_HOME"
test -d "$ANDROID_NDK_HOME" || { echo "NDK $NDK_VERSION not found at $ANDROID_NDK_HOME" >&2; exit 1; }

say "Building libbox.aar for $PLATFORMS"
go run ./cmd/internal/build_libbox -target android -platform "$PLATFORMS"

say "Verifying the built libraries contain AmneziaWG"
# The check that would have caught the original bug. Go keeps all strings in one
# blob, so only substring counts mean anything; `jmin` is a configuration key no
# other protocol uses, which makes its absence conclusive.
probe="$work/probe"
mkdir -p "$probe"
unzip -q -o libbox.aar -d "$probe"
found=0
for so in "$probe"/jni/*/libbox.so; do
  count="$(strings -a "$so" | grep -c jmin || true)"
  echo "  $(basename "$(dirname "$so")")  jmin=$count"
  if [ "$count" -lt 1 ]; then
    echo "core for $(basename "$(dirname "$so")") has no AmneziaWG in it" >&2
    exit 1
  fi
  found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "no native libraries in the AAR" >&2; exit 1; }

mkdir -p "$(dirname "$output")"
cp libbox.aar "$output"
say "Wrote $output"
shasum -a 256 "$output"
