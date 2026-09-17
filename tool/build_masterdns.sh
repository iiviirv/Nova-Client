#!/bin/zsh
# Builds the MasterDNS client engine for the desktop builds, from a pinned
# upstream commit, into assets/bin.
#
# Pinned and built from source rather than downloaded, for the same reason the
# other cores are: a binary fetched from someone else's release page is a
# binary nobody here can vouch for. Anyone can re-run this and compare.
#
# Upstream: github.com/masterking32/MasterDnsVPN (MIT). The engine is pure Go
# with pure-Go dependencies, so the desktop targets build with cgo off and need
# no toolchain beyond Go itself.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=https://github.com/masterking32/MasterDnsVPN.git
COMMIT=${MASTERDNS_COMMIT:-acbf1c61f90786f41b975d2e2f616afbce292b29}
OUT="$PWD/assets/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== fetching $COMMIT"
git init -q "$WORK/src"
git -C "$WORK/src" remote add origin "$REPO"
git -C "$WORK/src" fetch -q --depth 1 origin "$COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
got="$(git -C "$WORK/src" rev-parse HEAD)"
[[ "$got" == "$COMMIT" ]] || { echo "!! fetched $got, wanted $COMMIT"; exit 1 }

build() {
  local goos=$1 goarch=$2 name=$3
  echo "== $goos/$goarch -> $name"
  ( cd "$WORK/src" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch \
      go build -trimpath -ldflags "-s -w -buildid=" -o "$OUT/$name" ./cmd/client )
}

build darwin  arm64 masterdns-macos-arm64
build darwin  amd64 masterdns-macos-amd64
build windows amd64 masterdns-windows-amd64.exe
build linux   amd64 masterdns-linux-amd64

# Android runs the engine as its own process too, which also keeps it clear of
# sing-box, since both are Go and one process cannot hold two Go runtimes.
#
# It ships as lib<name>.so inside jniLibs. That is not a library: it is the
# executable under the only kind of name Android extracts into the app's native
# library directory, which is one of the few places an app may run a binary
# from. Built through the NDK with cgo on, because the 32-bit ARM and x86_64
# targets need external linking, and one toolchain for all three keeps them
# alike. API 24 matches the Aether core's floor.
NDK=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  echo "!! no Android NDK found; set ANDROID_NDK_HOME"; exit 1
fi
TC="$NDK/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin"
JNI="$PWD/android/app/src/main/jniLibs"

android() {
  local goarch=$1 abi=$2 cc=$3 extra=${4:-}
  echo "== android/$goarch -> jniLibs/$abi/libmasterdns.so"
  mkdir -p "$JNI/$abi"
  ( cd "$WORK/src" && env CGO_ENABLED=1 GOOS=android GOARCH=$goarch $extra \
      CC="$TC/$cc" \
      go build -trimpath -ldflags "-s -w -buildid=" -o "$JNI/$abi/libmasterdns.so" ./cmd/client )
}

android arm64 arm64-v8a   aarch64-linux-android24-clang
android arm   armeabi-v7a armv7a-linux-androideabi24-clang GOARM=7
android amd64 x86_64      x86_64-linux-android24-clang

echo "== result"
ls -lh "$OUT"/masterdns-* "$JNI"/*/libmasterdns.so
# The licence travels with the binaries: MIT requires the notice to ship.
cp "$WORK/src/LICENSE" "$OUT/LICENSE-masterdns.txt"
echo "built from $COMMIT"
