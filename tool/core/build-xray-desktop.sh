#!/usr/bin/env bash
# Build the standalone Xray CLI for the desktop app's second core (xhttp exits).
#
# The desktop app runs Xray as its own process (see
# lib/src/core/proxy/desktop_proxy_controller.dart and
# docs/desktop-xray-xhttp.md); this produces the binary it starts. The version is
# pinned to the SAME xray-core the combined mobile core uses
# (tool/core/xray/novaxray/go.mod), so all platforms run one Xray version.
#
# Usage:
#   tool/core/build-xray-desktop.sh macos   arm64   -> assets/bin/xray-macos-arm64
#   tool/core/build-xray-desktop.sh windows amd64   -> assets/bin/xray-windows-amd64.exe
#   tool/core/build-xray-desktop.sh linux   amd64   -> assets/bin/xray-linux-amd64
#   tool/core/build-xray-desktop.sh all             -> builds every target below
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
proj="$(cd "$here/../.." && pwd)"
# The pinned version, read straight from the mobile wrapper's go.mod so the two
# never drift. Falls back to the known-good tag if the grep ever misses.
XRAY_VERSION="$(awk '/xtls\/xray-core/ {print $2}' "$here/xray/novaxray/go.mod" | head -1)"
XRAY_VERSION="${XRAY_VERSION:-v1.260327.0}"

build_one() {
  local os="$1" arch="$2"
  local goos="$os" ext=""
  case "$os" in
    macos) goos="darwin" ;;
    windows) goos="windows"; ext=".exe" ;;
    linux) goos="linux" ;;
    *) echo "unknown os: $os" >&2; return 1 ;;
  esac
  local out="$proj/assets/bin/xray-$os-$arch$ext"
  local work; work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  echo "==> xray $XRAY_VERSION for $goos/$arch"
  ( cd "$work"
    go mod init novaxraycli >/dev/null 2>&1
    GOFLAGS=-mod=mod go get "github.com/xtls/xray-core@$XRAY_VERSION" >/dev/null 2>&1
    GOOS="$goos" GOARCH="$arch" CGO_ENABLED=0 GOFLAGS=-mod=mod \
      go build -trimpath -ldflags "-s -w" \
      -o "$out" "github.com/xtls/xray-core/main" )
  echo "    built $out ($(du -h "$out" | cut -f1))"
}

if [[ "${1:-}" == "all" || $# -eq 0 ]]; then
  build_one macos   arm64
  build_one windows amd64
  build_one linux   amd64
else
  build_one "$1" "$2"
fi
