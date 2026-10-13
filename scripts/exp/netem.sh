#!/bin/bash
# 给 Pi 的 eth0 出口加单向延迟（模拟更慢的网络），或者用 0 撤掉。需要 sudo 密码。
# 用法：PI_SUDO_PW=密码 scripts/exp/netem.sh 毫秒数 [用户@IP ...]      （默认：hosts.env 里的所有 Pi）
#   例：PI_SUDO_PW=... scripts/exp/netem.sh 1      所有 Pi 加 1 ms
#       PI_SUDO_PW=... scripts/exp/netem.sh 0      全部撤掉（做完实验一定要撤！）
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
: "${PI_SUDO_PW:?需要设置 PI_SUDO_PW（Pi 的 sudo 密码）}"
MS=${1:?用法：netem.sh 毫秒数 [用户@IP ...]}; shift
if [ "$MS" = 0 ]; then cmd="tc qdisc del dev eth0 root 2>/dev/null || true"; else cmd="tc qdisc replace dev eth0 root netem delay ${MS}ms"; fi
for h in ${*:-$ALL_PIS}; do
  printf '%s\n' "$PI_SUDO_PW" | ssh_pi "$h" "sudo -S -p '' sh -c '$cmd'; /usr/sbin/tc qdisc show dev eth0 | head -1" | sed "s/^/[$h] /" &
done; wait
