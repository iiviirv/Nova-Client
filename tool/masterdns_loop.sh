#!/bin/zsh
# Runs a MasterDNS server on this machine, so the client can be tested end to
# end without a real server anywhere.
#
# The client is pointed at 127.0.0.1:5353 as its resolver and asks for
# t.nova.test; this server answers for exactly that. Nothing leaves the machine
# except the traffic the server forwards on the client's behalf, which is the
# point of the test.
#
#   tool/masterdns_loop.sh -- flutter test integration_test/desktop_masterdns_test.dart -d macos
#
# MDNS_HOST and MDNS_PORT move it off loopback, for a phone on the same network.
# Avoid 5353 on a real interface: that is multicast DNS, and the system already
# listens there. Stop it as soon as the test is done, because anything that can
# reach it and knows the test key can use it.
set -euo pipefail
MDNS_HOST=${MDNS_HOST:-127.0.0.1}
MDNS_PORT=${MDNS_PORT:-5353}
cd "$(dirname "$0")/.."
PROJ="$PWD"
COMMIT=${MASTERDNS_COMMIT:-acbf1c61f90786f41b975d2e2f616afbce292b29}
WORK="$(mktemp -d)"
cleanup() { [[ -n "${SRV:-}" ]] && kill -KILL "$SRV" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

git init -q "$WORK/src"
git -C "$WORK/src" remote add origin https://github.com/masterking32/MasterDnsVPN.git
git -C "$WORK/src" fetch -q --depth 1 origin "$COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
( cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/server" ./cmd/server )

mkdir -p "$WORK/run" && cd "$WORK/run"
printf '%s' 0123456789abcdef0123456789abcdef > encrypt_key.txt
sed -e 's/^DOMAIN = .*/DOMAIN = ["t.nova.test"]/' \
    -e "s/^UDP_HOST = .*/UDP_HOST = \"$MDNS_HOST\"/" \
    -e "s/^UDP_PORT = .*/UDP_PORT = $MDNS_PORT/" \
    "$WORK/src/server_config.toml.simple" > server_config.toml
"$WORK/server" -config server_config.toml > "$WORK/server.log" 2>&1 &
SRV=$!
perl -e 'select(undef,undef,undef,1.5)'
echo "masterdns test server up on $MDNS_HOST:$MDNS_PORT (pid $SRV)"

[[ "${1:-}" == "--" ]] && shift
cd "$PROJ"
"$@"
