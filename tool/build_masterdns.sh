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

echo "== result"
ls -lh "$OUT"/masterdns-*
# The licence travels with the binaries: MIT requires the notice to ship.
cp "$WORK/src/LICENSE" "$OUT/LICENSE-masterdns.txt"
echo "built from $COMMIT"
