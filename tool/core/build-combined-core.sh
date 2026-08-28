#!/usr/bin/env bash
# Build Nova's COMBINED core: sing-box (AmneziaWG + nova_fragment) AND xray-core
# (for the xhttp/SplitHTTP transport) in ONE gomobile module, so both share a
# single go.Seq / runtime in one libbox.aar.
#
# Two separate gomobile .aar files cannot coexist (duplicate `go` runtime), so
# Xray is bound alongside sing-box here: the wrapper tool/core/xray/novaxray is
# copied into the sing-box tree, xray-core is added to sing-box's go.mod, and
# build_libbox is patched to bind ./novaxray next to ./experimental/libbox. The
# result exports io.nekohasekai.libbox.* AND io.nekohasekai.novaxray.*.
#
# Usage:  tool/core/build-combined-core.sh [output.aar]   (default: app/libs/libbox.aar)
# Needs:  go, JDK 17, the Android SDK + pinned NDK, git, unzip, shasum.
set -euo pipefail

SINGBOX_TAG="v1.13.19"
SINGBOX_COMMIT="b5ebaa1fc0f2b94256180b95468e73ef53caa27d"
PATCH_SHA256="92aeac11c2b92118dab046dbae8ffaba41b368649f252c04b42e9924ed46f350"
NOVAFRAG_PATCH_SHA256="3168ae867e65ef57689aeb4734ff488920f1c333e42ac8b506e25111893ac92c"
XRAY_VERSION="${XRAY_VERSION:-v1.260327.0}"
NDK_VERSION="${NDK_VERSION:-28.0.13004108}"
PLATFORMS="${PLATFORMS:-android/arm64,android/arm,android/amd64}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
patch_file="$repo_root/tool/core/amneziawg.patch"
novafrag_file="$repo_root/tool/core/novafrag.patch"
novaxray_src="$repo_root/tool/core/xray/novaxray/xray.go"
mieru_out="$repo_root/tool/core/mieru/outbound.go"
mieru_opt="$repo_root/tool/core/mieru/option_mieru.go"
output="${1:-$repo_root/android/app/libs/libbox.aar}"
say() { printf '\n== %s\n' "$1"; }

for f in "$patch_file:$PATCH_SHA256" "$novafrag_file:$NOVAFRAG_PATCH_SHA256"; do
  p="${f%%:*}"; want="${f##*:}"
  got="$(shasum -a 256 "$p" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "patch SHA mismatch for $p ($got != $want)" >&2; exit 1; }
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

say "Cloning sing-box $SINGBOX_TAG"
git clone --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box "$work/sing-box"
cd "$work/sing-box"
[ "$(git rev-parse HEAD)" = "$SINGBOX_COMMIT" ] || { echo "tag moved off $SINGBOX_COMMIT" >&2; exit 1; }

say "Applying the AmneziaWG + nova_fragment patches"
git apply --verbose "$patch_file"
git apply --verbose "$novafrag_file"

say "Folding in the Xray wrapper (novaxray) + xray-core $XRAY_VERSION"
mkdir -p novaxray
cp "$novaxray_src" novaxray/xray.go
export GOFLAGS=-mod=mod
go get "github.com/xtls/xray-core@$XRAY_VERSION"
go mod tidy
# Bind ./novaxray alongside ./experimental/libbox in both the android and apple paths.
perl -0pi -e 's{args = append\(args, "\./experimental/libbox"\)}{args = append(args, "./experimental/libbox", "./novaxray")}g' \
  cmd/internal/build_libbox/main.go
grep -q '"./novaxray"' cmd/internal/build_libbox/main.go || { echo "failed to patch build_libbox" >&2; exit 1; }

say "Folding in the mieru outbound (enfein/mieru/v3)"
mkdir -p protocol/mieru
cp "$mieru_out" protocol/mieru/outbound.go
cp "$mieru_opt" option/mieru.go
# The mbox outbound needs a TypeMieru constant + a registration that stock
# sing-box lacks; add both, then pull the mieru library.
perl -0pi -e 's{(\tTypeNaive\s+= "naive"\n)}{$1\tTypeMieru = "mieru"\n}' constant/proxy.go
grep -q 'TypeMieru' constant/proxy.go || { echo "failed to add TypeMieru" >&2; exit 1; }
perl -0pi -e 's{(\t"github.com/sagernet/sing-box/protocol/naive"\n)}{$1\t"github.com/sagernet/sing-box/protocol/mieru"\n}' include/registry.go
perl -0pi -e 's{(\tregisterNaiveOutbound\(registry\)\n)}{$1\tmieru.RegisterOutbound(registry)\n}' include/registry.go
grep -q 'mieru.RegisterOutbound' include/registry.go || { echo "failed to register mieru" >&2; exit 1; }
go get github.com/enfein/mieru/v3@v3.36.0
go mod tidy

say "Proving the patched source builds an AmneziaWG endpoint"
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
test -d "$ANDROID_NDK_HOME" || { echo "NDK not found at $ANDROID_NDK_HOME" >&2; exit 1; }

say "Building the combined libbox.aar for $PLATFORMS"
go run ./cmd/internal/build_libbox -target android -platform "$PLATFORMS"

say "Verifying both cores are in the AAR"
probe="$work/probe"; mkdir -p "$probe"; unzip -q -o libbox.aar -d "$probe"
# NB: use grep -c (reads the whole listing), not grep -q. Under `set -o pipefail`
# grep -q short-circuits on the first match, `unzip -l` then dies on SIGPIPE, and
# the pipeline reports failure even though the class is present -> a false
# "missing from AAR". grep -c consumes all input, so no SIGPIPE.
[ "$(unzip -l "$probe/classes.jar" | grep -c 'novaxray/Novaxray.class')" -ge 1 ] || { echo "novaxray missing from AAR" >&2; exit 1; }
[ "$(unzip -l "$probe/classes.jar" | grep -c 'go/Seq.class')" = "1" ] || { echo "duplicate go.Seq" >&2; exit 1; }
for so in "$probe"/jni/*/libbox.so; do
  jmin="$(strings -a "$so" | grep -c jmin || true)"
  xh="$(strings -a "$so" | grep -c -i splithttp || true)"
  # NaiveProxy rides on Chromium's cronet; a with_naive_outbound core statically
  # links it, so a Cronet_Engine symbol is the reliable "naive is really in here"
  # signal. An Android core without it would run every other protocol and fail
  # only NaiveProxy servers, which reads as a dead server.
  nv="$(strings -a "$so" | grep -c -i 'Cronet_Engine' || true)"
  mu="$(strings -a "$so" | grep -c -i 'enfein/mieru' || true)"
  echo "  $(basename "$(dirname "$so")")  amneziawg(jmin)=$jmin  xray(splithttp)=$xh  naive(cronet)=$nv  mieru=$mu"
  [ "$jmin" -ge 1 ] && [ "$xh" -ge 1 ] && [ "$nv" -ge 1 ] && [ "$mu" -ge 1 ] || { echo "core for $(basename "$(dirname "$so")") missing a protocol (awg/xray/naive/mieru)" >&2; exit 1; }
done

mkdir -p "$(dirname "$output")"; cp libbox.aar "$output"
say "Wrote $output"; shasum -a 256 "$output"
