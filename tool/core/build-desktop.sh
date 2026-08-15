#!/usr/bin/env bash
# Build Nova's desktop sing-box cores (macOS arm64, Windows amd64) from the SAME
# pinned upstream tag and AmneziaWG patch as the Android core.
#
# Why this exists: the desktop binaries that shipped through v1.3.0-beta were
# stock sing-box 1.10/1.11 built with
#   with_gvisor,with_quic,with_utls,with_clash_api,with_grpc
# and nothing else. No with_wireguard (so plain WireGuard failed on desktop), no
# with_naive_outbound (a NaiveProxy server made the core exit at startup), and
# no AmneziaWG at all. The app's config layer had been emitting all three for
# months. This builds a core that can actually run what the app asks of it, and
# refuses to hand back one that cannot.
#
# Usage:  tool/core/build-desktop.sh [darwin|windows|all]   (default: all)
# Needs:  go, git, shasum. No CGO: both targets cross-compile from macOS.
# See docs/core-amneziawg.md for the pinning record.

set -euo pipefail

SINGBOX_TAG="v1.13.13"
SINGBOX_COMMIT="78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba"
PATCH_SHA256="a59362878c14227b9aa43ccee03da5dc6bbc0d867a029ba2a29cfc74e93c994f"

# The Android core's tag set plus with_grpc, which the old desktop binaries had
# and which the desktop config path may rely on for gRPC transports.
TAGS="with_gvisor,with_quic,with_wireguard,with_awg,with_utls,with_clash_api,with_naive_outbound,with_grpc"

# NaiveProxy in sing-box 1.13 is Chromium's network stack (cronet). It links two
# different ways, and the build has to know which:
#   macOS   cgo, statically against lib/darwin_arm64/libcronet.a. Needs the
#           native toolchain, so this target is built on a Mac with CGO on.
#   Windows purego. The Go side is pure and cross-compiles from macOS with CGO
#           off, and it loads libcronet.dll at runtime from the executable's
#           directory. That DLL is shipped in assets/bin beside the core, the way
#           wintun.dll already is, and the desktop controller mirrors it into the
#           run directory. The load is lazy: a user who never opens a Naive
#           server never touches it.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patch_file="$repo_root/tool/core/amneziawg.patch"
out_dir="$repo_root/assets/bin"
target="${1:-all}"

say() { printf '\n== %s\n' "$1"; }

say "Checking the patch is the pinned one"
actual="$(shasum -a 256 "$patch_file" | cut -d' ' -f1)"
if [ "$actual" != "$PATCH_SHA256" ]; then
  echo "patch SHA-256 mismatch: expected $PATCH_SHA256, got $actual" >&2
  echo "If the patch was changed on purpose, update PATCH_SHA256 in BOTH build" >&2
  echo "scripts and docs/core-amneziawg.md in the same commit." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Cloning sing-box $SINGBOX_TAG"
git clone --quiet --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box "$work/sing-box"
cd "$work/sing-box"
head="$(git rev-parse HEAD)"
if [ "$head" != "$SINGBOX_COMMIT" ]; then
  echo "upstream tag $SINGBOX_TAG now points at $head, not $SINGBOX_COMMIT" >&2
  echo "A moved tag is a supply-chain event, not a build failure. Stop and look." >&2
  exit 1
fi

say "Applying the AmneziaWG patch"
git apply "$patch_file"

# Reproducible bytes for one toolchain, same flags as the Android build.
LDFLAGS="-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=${SINGBOX_TAG#v}-nova"

build() {
  local goos="$1" goarch="$2" out="$3" cgo="$4" tags="$5"
  say "Building $goos/$goarch (CGO_ENABLED=$cgo, tags $tags)"
  CGO_ENABLED="$cgo" GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -buildvcs=false -tags "$tags" -ldflags "$LDFLAGS" \
      -o "$out" ./cmd/sing-box
  ls -lh "$out" | awk '{print "  " $5, $9}'
}

# The cronet DLL the Windows core loads for NaiveProxy, taken from the exact
# module version the patched tree resolves to (so the DLL and the Go bindings
# that call into it were built together).
cronet_dll() {
  local dir
  dir="$(go list -m -f '{{.Dir}}' github.com/sagernet/cronet-go/lib/windows_amd64 2>/dev/null || true)"
  if [ -z "$dir" ] || [ ! -f "$dir/libcronet.dll" ]; then
    echo "cannot locate lib/windows_amd64/libcronet.dll in the module cache" >&2
    exit 1
  fi
  printf '%s' "$dir/libcronet.dll"
}

# Refuse to ship a core that cannot run what the app emits. `check` parses and
# initialises the outbounds, so a missing build tag surfaces here as
# "<x> is not included in this build". These probes carry no real credentials.
verify() {
  local bin="$1"
  say "Verifying $(basename "$bin") accepts naive, wireguard and awg"
  local probe="$work/probe.json"
  cat > "$probe" <<'JSON'
{
  "log": {"level": "error"},
  "endpoints": [
    {"type": "awg", "tag": "awg-probe",
     "address": ["10.9.0.2/32"],
     "private_key": "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=",
     "peers": [{"address": "127.0.0.1", "port": 1, "public_key": "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=",
                "allowed_ips": ["0.0.0.0/0"]}],
     "jc": 4, "jmin": 40, "jmax": 70, "s1": 0, "s2": 0, "h1": 1, "h2": 2, "h3": 3, "h4": 4}
  ],
  "outbounds": [
    {"type": "naive", "tag": "naive-probe", "server": "127.0.0.1", "server_port": 1,
     "username": "u", "password": "p", "tls": {"enabled": true, "server_name": "example.invalid"}},
    {"type": "direct", "tag": "direct"}
  ]
}
JSON
  local out
  if [ "$(uname -s)" = "Darwin" ] && [[ "$bin" == *darwin* || "$bin" == *macos* ]]; then
    out="$("$bin" check -c "$probe" 2>&1 || true)"
    if echo "$out" | grep -qi "not included in this build"; then
      echo "$out" >&2
      echo "core is missing a protocol it must have" >&2
      exit 1
    fi
    echo "  check passed"
  else
    # Cannot execute a foreign binary; fall back to the same string evidence the
    # Android build uses. `jmin` is an AmneziaWG-only key.
    for needle in jmin naive.NewOutbound; do
      local n
      n="$(strings -a "$bin" | grep -c "$needle" || true)"
      echo "  $needle=$n"
      [ "$n" -ge 1 ] || { echo "core lacks $needle" >&2; exit 1; }
    done
  fi
}

mkdir -p "$out_dir"
if [ "$target" = "darwin" ] || [ "$target" = "all" ]; then
  [ "$(uname -s)" = "Darwin" ] || { echo "the macOS core needs cgo and must be built on a Mac" >&2; exit 1; }
  build darwin arm64 "$work/sing-box-macos-arm64" 1 "$TAGS"
  verify "$work/sing-box-macos-arm64"
  cp "$work/sing-box-macos-arm64" "$out_dir/sing-box-macos-arm64"
  chmod +x "$out_dir/sing-box-macos-arm64"
fi
if [ "$target" = "windows" ] || [ "$target" = "all" ]; then
  build windows amd64 "$work/sing-box-windows-amd64.exe" 0 "$TAGS,with_purego"
  verify "$work/sing-box-windows-amd64.exe"
  cp "$work/sing-box-windows-amd64.exe" "$out_dir/sing-box-windows-amd64.exe"
  dll="$(cronet_dll)"
  cp "$dll" "$out_dir/libcronet.dll"
  ls -lh "$out_dir/libcronet.dll" | awk '{print "  " $5, $9}'
fi

say "Done"
shasum -a 256 "$out_dir"/sing-box-* | sed 's/^/  /'
