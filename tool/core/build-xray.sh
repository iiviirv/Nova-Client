#!/usr/bin/env bash
# Phase-1 spike: build the Xray core as an Android .aar (novaxray wrapper).
#
# This proves Nova can run Xray-only transports (xhttp / SplitHTTP) on Android.
# It is NOT yet wired into the shipped app — that is Phase-2 (a tun2socks bridge
# from the VpnService TUN to Xray's local socks inbound, plus dual-core routing).
# See docs/xray-core-scope.md.
#
# Usage:  tool/core/build-xray.sh [output.aar]   (default: /tmp/libxray.aar)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_dir="$here/xray/novaxray"
out="${1:-/tmp/libxray.aar}"

: "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/28.2.13676358}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME ANDROID_HOME
export PATH="$PATH:$(go env GOPATH)/bin"
export GOFLAGS=-mod=mod

echo "Installing gomobile/gobind…"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

echo "Tidying $pkg_dir…"
( cd "$pkg_dir" && go mod tidy && go build ./... )

# All runnable Android ABIs. arm64 alone for a quick spike; the full set matches
# what the sing-box AAR ships.
platforms="${XRAY_PLATFORMS:-android/arm64,android/arm,android/amd64,android/386}"

echo "gomobile bind ($platforms) -> $out"
( cd "$pkg_dir" && gomobile bind \
    -target="$platforms" \
    -androidapi 23 \
    -javapkg=online.novaproxy.xray \
    -o "$out" \
    nova/novaxray )

echo "Built $out ($(du -h "$out" | cut -f1))"
