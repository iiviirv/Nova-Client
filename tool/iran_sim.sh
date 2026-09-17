#!/bin/zsh
# Makes this Mac's path to one WARP gateway slow and lossy, runs the Aether
# verification against it, and puts the network back.
#
# The question it answers: the core gives verification a fixed five second
# budget, and on a healthy network the check finishes in about half a second.
# Does a path bad enough to look like a congested link from Iran push that past
# five seconds, so a gateway that is genuinely fine reports itself unhealthy?
#
# Scoped deliberately narrow. Only UDP to the one gateway is touched, so
# nothing else on the machine changes, and the existing pf ruleset is kept and
# restored rather than replaced.
set -e

GW=162.159.198.1
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ME="${SUDO_USER:-$USER}"

[[ $EUID -eq 0 ]] || { echo "run this with sudo"; exit 1 }

# Refuse to run on a machine that is already using pf.
#
# The earlier version copied /etc/pf.conf and restored that on the way out,
# which is not the same thing as the ruleset that was actually loaded: anyone
# running a firewall product would have had their live rules replaced by the
# stock file. Capturing the real ruleset faithfully (filter, nat, anchors, in
# the right order) is more than a test harness should be attempting, so it does
# not attempt it. If pf is off, restoring the on-disk default and turning it
# back off afterwards is exactly right, and that is the only case allowed here.
if pfctl -s info 2>/dev/null | head -1 | grep -q Enabled; then
  echo "!! pf is already enabled on this machine."
  echo "   This harness only runs when pf is off, because it cannot put a"
  echo "   ruleset it did not load back the way it found it."
  exit 1
fi

PF_TOKEN=""

cleanup() {
  echo
  echo "=== putting the network back ==="
  pfctl -a nova -F all 2>/dev/null || true
  dnctl pipe 1 delete 2>/dev/null || true
  # Release our own enable reference rather than disabling pf outright. `-d`
  # would tear down the firewall for anything else holding a reference too.
  if [[ -n "$PF_TOKEN" ]]; then
    pfctl -X "$PF_TOKEN" 2>/dev/null || true
  fi
  # pf was off when we started, so the on-disk default is what it should go
  # back to, and it should end up disabled.
  pfctl -f /etc/pf.conf 2>/dev/null || true
  pfctl -d 2>/dev/null || true
  echo "done"
}
trap cleanup EXIT INT TERM

run_case() {
  local delay="$1" plr="$2"
  echo
  echo "=== one-way delay ${delay}ms, loss ${plr} (RTT about $((delay * 2))ms) ==="
  dnctl pipe 1 config delay "$delay" plr "$plr"
  sudo -u "$ME" -H env PATH="$PATH" sh -c \
    "cd '$REPO' && flutter test integration_test/aether_degraded_test.dart -d macos 2>&1 | grep -E 'DEGRADED|Some tests'"
}

# Load the rule once: everything after this just reconfigures the pipe.
{ cat /etc/pf.conf; echo 'dummynet-anchor "nova"'; echo 'anchor "nova"' } | pfctl -f - 2>/dev/null
echo "dummynet out proto udp from any to $GW pipe 1" | pfctl -a nova -f - 2>/dev/null
# `-E` hands back a reference token. Keeping it is what lets cleanup release
# just ours instead of disabling pf for the whole machine.
PF_TOKEN="$(pfctl -E 2>&1 | awk '/Token/ {print $3}')" 

echo "baseline for comparison was about 500ms on an untouched network"
run_case 60  0
run_case 150 0.02
run_case 300 0.05
run_case 600 0.10
