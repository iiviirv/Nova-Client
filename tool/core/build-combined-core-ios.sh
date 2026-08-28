#!/usr/bin/env bash
# Build the COMBINED iOS/macOS core (Novacore.xcframework): sing-box (AmneziaWG +
# nova_fragment, renamed experimental/libbox -> experimental/novacore) AND
# xray-core (novaxray) in one gomobile framework, so the iOS Network Extension
# can run xhttp the same way Android does.
#
# Mirrors build-combined-core.sh but for Apple: it also does the novacore rename
# and binds ./experimental/novacore + ./novaxray with the iOS tags/ldflags from
# build-novacore-ios.sh.
#
# Usage: tool/core/build-combined-core-ios.sh [out.xcframework]
set -euo pipefail

SINGBOX_TAG="v1.13.13"
SINGBOX_COMMIT="78b2e12fbdd85e6ec956647d6f79cf0bba85c6ba"
PATCH_SHA256="c37f41ebd2ea5750c5a96a7da94743eb7dc510fbe357c872f781cca33602ee24"
NOVAFRAG_PATCH_SHA256="3168ae867e65ef57689aeb4734ff488920f1c333e42ac8b506e25111893ac92c"
XRAY_VERSION="${XRAY_VERSION:-v1.260327.0}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patch_file="$repo_root/tool/core/amneziawg.patch"
novafrag_file="$repo_root/tool/core/novafrag.patch"
novaxray_src="$repo_root/tool/core/xray/novaxray/xray.go"
mieru_out="$repo_root/tool/core/mieru/outbound.go"
mieru_opt="$repo_root/tool/core/mieru/option_mieru.go"
OUT="${1:-$repo_root/ios/Frameworks/Novacore.xcframework}"
say() { printf '\n== %s\n' "$1"; }

for f in "$patch_file:$PATCH_SHA256" "$novafrag_file:$NOVAFRAG_PATCH_SHA256"; do
  p="${f%%:*}"; want="${f##*:}"
  got="$(shasum -a 256 "$p" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "patch SHA mismatch for $p" >&2; exit 1; }
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
say "Cloning sing-box $SINGBOX_TAG"
git clone --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box "$work/sing-box"
cd "$work/sing-box"
[ "$(git rev-parse HEAD)" = "$SINGBOX_COMMIT" ] || { echo "tag moved" >&2; exit 1; }

say "Applying patches"
git apply --verbose "$patch_file"
git apply --verbose "$novafrag_file"

say "Renaming experimental/libbox -> experimental/novacore (de-fingerprint)"
cp -r experimental/libbox experimental/novacore
# Rename the Go package in every file, and fix internal self-imports.
find experimental/novacore -name '*.go' -exec sed -i '' \
  -e 's#^package libbox#package novacore#' \
  -e 's#experimental/libbox#experimental/novacore#g' {} +
printf '1.13.13-nova\n' > .version

say "Folding in the Xray wrapper (novaxray) + xray-core $XRAY_VERSION"
mkdir -p novaxray
cp "$novaxray_src" novaxray/xray.go
export GOFLAGS=-mod=mod
go get "github.com/xtls/xray-core@$XRAY_VERSION"
go mod tidy

say "Folding in the mieru outbound (enfein/mieru/v3)"
mkdir -p protocol/mieru
cp "$mieru_out" protocol/mieru/outbound.go
cp "$mieru_opt" option/mieru.go
perl -0pi -e 's{(\tTypeNaive\s+= "naive"\n)}{$1\tTypeMieru = "mieru"\n}' constant/proxy.go
grep -q 'TypeMieru' constant/proxy.go || { echo "failed to add TypeMieru" >&2; exit 1; }
perl -0pi -e 's{(\t"github.com/sagernet/sing-box/protocol/naive"\n)}{$1\t"github.com/sagernet/sing-box/protocol/mieru"\n}' include/registry.go
perl -0pi -e 's{(\tregisterNaiveOutbound\(registry\)\n)}{$1\tmieru.RegisterOutbound(registry)\n}' include/registry.go
grep -q 'mieru.RegisterOutbound' include/registry.go || { echo "failed to register mieru" >&2; exit 1; }
GOFLAGS=-mod=mod go get github.com/enfein/mieru/v3@v3.36.0
GOFLAGS=-mod=mod go mod tidy

say "Installing the pinned gomobile"
export PATH="$PATH:$(go env GOPATH)/bin"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12

TAGS="with_gvisor,with_quic,with_wireguard,with_awg,with_utls,with_naive_outbound,with_clash_api,badlinkname,tfogo_checklinkname0,with_tailscale,ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient,ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology,ts_omit_bird,with_dhcp,grpcnotrace"
CT="$(cat .version)"

say "Binding the combined Novacore.xcframework (novacore + novaxray)"
rm -rf "$OUT"
gomobile bind -v -target ios,iossimulator -libname=core \
  -tags-not-macos=with_low_memory \
  -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$CT -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0" \
  -tags "$TAGS" \
  -o "$OUT" \
  ./experimental/novacore ./novaxray

say "Verifying both cores are in the framework"
grep -rq "NovacoreCommandClient" "$OUT" || { echo "novacore missing" >&2; exit 1; }
grep -rq "NovaxrayStart" "$OUT" || { echo "novaxray missing" >&2; exit 1; }
echo "OK: framework has both Novacore* and Novaxray*"
ls -la "$OUT"
