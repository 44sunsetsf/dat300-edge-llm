#!/bin/bash
# Add (or with 0, remove) one-way delay on a Pi's eth0 egress. Usage: PI_SUDO_PW=... scripts/exp/netem.sh user@ip MS
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
: "${PI_SUDO_PW:?set PI_SUDO_PW}"
if [ "$2" = 0 ]; then cmd="tc qdisc del dev eth0 root 2>/dev/null || true"; else cmd="tc qdisc replace dev eth0 root netem delay ${2}ms"; fi
printf '%s\n' "$PI_SUDO_PW" | ssh_pi "$1" "sudo -S -p '' sh -c '$cmd'; tc qdisc show dev eth0 | head -1"
