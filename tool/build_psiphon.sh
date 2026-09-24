#!/bin/zsh
# Builds the Psiphon tunnel core for every Nova platform, from a pinned commit,
# into assets/bin and android/app/src/main/jniLibs.
#
# Pinned and built from source for the same reason the other cores are: a binary
# from someone else's release page is a binary nobody here can vouch for.
#
# Upstream is Psiphon-Labs/psiphon-tunnel-core (GPL-3.0). Nova builds a fork
# that adds a CDN fronting scan, SOCKS UDP associate and local proxy auth. That
# fork was reviewed at the pinned commit; see docs/psiphon-fork-review.md.
#
# The pin is checked after fetching and the build STOPS if it does not match.
# Aether's own psiphon-build.sh falls back to "the branch as it stands" when the
# pinned commit is gone, which would silently build unreviewed code into a
# censorship tool. Nova does not do that.
set -euo pipefail
cd "$(dirname "$0")/.."

# Overridable so this can be pointed at a fork under our own account without
# editing the script. Whatever it points at, the commit below must match.
REPO=${PSIPHON_REPO:-https://github.com/CluvexStudio/psiphon-tunnel-core.git}
COMMIT=${PSIPHON_COMMIT:-83aa73b9b982e7421e00117f5b0c5aceb5dda452}
OUT="$PWD/assets/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== fetching $COMMIT"
git init -q "$WORK/src"
git -C "$WORK/src" remote add origin "$REPO"
# A fork carries the commit on a branch, so fetch the object directly. Depth 1
# keeps this honest: nothing but the pinned tree is ever checked out.
git -C "$WORK/src" fetch -q --depth 1 origin "$COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
got="$(git -C "$WORK/src" rev-parse HEAD)"
[[ "$got" == "$COMMIT" ]] || { echo "!! fetched $got, wanted $COMMIT"; exit 1 }

# -buildid= is what makes two builds of the same source byte-identical, which is
# the only way anyone can check this binary is the pinned source and nothing else.
LD="-s -w -buildid="

build() {
  local goos=$1 goarch=$2 name=$3
  echo "== $goos/$goarch -> $name"
  ( cd "$WORK/src" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch GOFLAGS=-mod=vendor \
      go build -trimpath -ldflags "$LD" -o "$OUT/$name" ./ConsoleClient )
}

build darwin  arm64 psiphon-macos-arm64
build darwin  amd64 psiphon-macos-amd64
build windows amd64 psiphon-windows-amd64.exe
build linux   amd64 psiphon-linux-amd64

# Android runs it as its own process, which also keeps it clear of sing-box:
# both are Go and one process cannot hold two Go runtimes. It ships as
# lib<name>.so inside jniLibs, the only kind of name Android extracts into the
# native library directory, which is one of the few places an app may exec from.
# API 24 matches the Aether core's floor.
NDK=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* 2>/dev/null | sort -V | tail -1)}
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  echo "!! no Android NDK found; set ANDROID_NDK_HOME"; exit 1
fi
TC="$NDK/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin"
JNI="$PWD/android/app/src/main/jniLibs"

# Two Android-only linker flags, both taken from upstream Psiphon's own
# MobileLibrary/Android/make.bash rather than invented here:
#
#   -checklinkname=0  an in-proxy dependency (wlynxg/anet) reaches net.zoneCache
#                     through //go:linkname, which Go 1.23 and later refuse by
#                     default. Without this the link fails outright.
#   max-page-size     Android 15 requires 16KB page alignment, and Nova targets
#                     SDK 35. A 4KB-aligned binary will not load on those devices.
ANDROID_LD="$LD -checklinkname=0 -extldflags=-Wl,-z,max-page-size=16384,-z,common-page-size=16384"

android() {
  local goarch=$1 abi=$2 cc=$3 extra=${4:-}
  echo "== android/$goarch -> jniLibs/$abi/libpsiphon.so"
  mkdir -p "$JNI/$abi"
  ( cd "$WORK/src" && env CGO_ENABLED=1 GOOS=android GOARCH=$goarch $extra \
      GOFLAGS=-mod=vendor CC="$TC/$cc" \
      go build -trimpath -ldflags "$ANDROID_LD" -o "$JNI/$abi/libpsiphon.so" ./ConsoleClient )
}

android arm64 arm64-v8a   aarch64-linux-android24-clang
android arm   armeabi-v7a armv7a-linux-androideabi24-clang GOARM=7
android amd64 x86_64      x86_64-linux-android24-clang

echo "== result"
ls -lh "$OUT"/psiphon-* "$JNI"/*/libpsiphon.so
# GPL-3.0 requires the notice to ship beside the binaries.
cp "$WORK/src/LICENSE" "$OUT/LICENSE-psiphon.txt"
echo "built from $COMMIT"
