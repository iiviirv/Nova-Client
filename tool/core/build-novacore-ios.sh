#!/usr/bin/env bash
# Build the iOS/macOS Novacore.xcframework from a patched sing-box tree.
#
# The framework binds github.com/sagernet/sing-box/experimental/novacore, which
# is experimental/libbox renamed (a de-fingerprinting rename), not a stock
# package. This script takes an already-patched, already-renamed sing-box tree
# (amnezia + novafrag applied, experimental/novacore present) via $1 and binds
# it. build-libbox.sh / build-desktop.sh show how to produce that tree.
#
# Usage: tool/core/build-novacore-ios.sh <patched-sing-box-tree> [out.xcframework]
set -e
SRC="${1:?usage: build-novacore-ios.sh <patched-sing-box-tree> [out]}"
OUT="${2:-$(cd "$(dirname "$0")/../.." && pwd)/ios/Frameworks/Novacore.xcframework}"
cd "$SRC"
export PATH="$PATH:$(go env GOPATH)/bin"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
TAGS="with_gvisor,with_quic,with_wireguard,with_awg,with_utls,with_naive_outbound,with_clash_api,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_dhcp,grpcnotrace"
CT=$(cat .version 2>/dev/null || echo 1.13.13-nova)
rm -rf "$OUT"
gomobile bind -v -target ios,iossimulator -libname=core \
  -tags-not-macos=with_low_memory \
  -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$CT -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0" \
  -tags "$TAGS" \
  -o "$OUT" \
  ./experimental/novacore
echo "BIND EXIT $?"
ls -la "$OUT"
