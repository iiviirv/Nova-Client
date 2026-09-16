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
BACKUP="$(mktemp)"

[[ $EUID -eq 0 ]] || { echo "run this with sudo"; exit 1 }

cleanup() {
  echo
  echo "=== putting the network back ==="
  pfctl -a nova -F all 2>/dev/null || true
  dnctl pipe 1 delete 2>/dev/null || true
  pfctl -f "$BACKUP" 2>/dev/null || true
  [[ -s /tmp/nova-pf-was-enabled ]] || pfctl -d 2>/dev/null || true
  rm -f "$BACKUP" /tmp/nova-pf-was-enabled
  echo "done"
}
trap cleanup EXIT INT TERM

pfctl -s info 2>/dev/null | head -1 | grep -q Enabled && touch /tmp/nova-pf-was-enabled || true
cp /etc/pf.conf "$BACKUP"

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
pfctl -E 2>/dev/null || true

echo "baseline for comparison was about 500ms on an untouched network"
run_case 60  0
run_case 150 0.02
run_case 300 0.05
run_case 600 0.10
