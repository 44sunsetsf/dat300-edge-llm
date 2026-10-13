#!/bin/bash
# 实验前的体检：逐台检查 SSH、型号、系统、CPU 频率、内存、磁盘、温度、是否降频、网口速度、
# llama.cpp 版本、残留进程，以及从 HEAD 到每台的 ping。有问题的项会标 "!!"。
# 用法：scripts/check_cluster.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "主机 | 型号 | 系统 | CPU最高频率 | 内存总/可用 | 磁盘可用 | 温度 | 降频标志 | 网口 | 改进版 | 原版 | 残留进程 | HEAD→ping"
check_one() {
  local h=$1 info p
  info=$(ssh_pi "$h" '
    m=$(tr -d "\0" < /proc/device-tree/model | sed "s/Raspberry Pi/RPi/; s/ Rev.*//")
    os="Debian$(. /etc/os-release; echo $VERSION_ID)-$(uname -m | sed s/aarch64/64位/)"
    f="$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000 ))MHz"
    mem=$(awk "/MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{printf \"%.1f/%.1fG\", t/1048576, a/1048576}" /proc/meminfo)
    disk=$(df -h ~ | awk "NR==2{print \$4}")
    t=$(vcgencmd measure_temp 2>/dev/null | grep -oE "[0-9.]+"); th=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    sp=$(cat /sys/class/net/eth0/speed 2>/dev/null)
    vo=$(cut -c1-7 ~/llama.cpp/build/bin/VERSION 2>/dev/null); vs=$(cut -c1-7 ~/llama.cpp/build-stock/bin/VERSION 2>/dev/null)
    pr=$(pgrep -x ggml-rpc-server >/dev/null && echo rpc-server; pgrep -x llama-bench >/dev/null && echo llama-bench; { pgrep -x dllama || pgrep -x dllama-api; } >/dev/null && echo dllama)
    echo "$m|$os|$f|$mem|$disk|${t:-?}C|${th:-?}|${sp:-?}Mb|${vo:-无}|${vs:-无}|$(echo $pr)"' 2>/dev/null) || { echo "$h | !! SSH 连不上"; return; }
  p=$(ssh_pi "$HEAD" "ping -c 3 -q $(ip_of "$h") | awk -F/ '/rtt/{print \$5\" ms\"}'" 2>/dev/null)
  echo "$h|$info|${p:-!!不通}" | awk -F'|' -v OFS=' | ' -v opt="${LLAMA_COMMIT:0:7}" -v stk="${LLAMA_STOCK_COMMIT:0:7}" '{
    $1 = $1
    if ($3 !~ /64位/) $3 = "!!" $3 "(要重装64位系统)"
    if ($7 + 0 >= 75) $7 = "!!" $7
    if ($8 != "0x0") $8 = "!!" $8
    if ($9 != "1000Mb") $9 = "!!" $9
    if ($10 != opt) $10 = "!!" $10
    if ($11 != stk) $11 = "!!" $11
    if ($12 ~ /[a-z]/) $12 = "!!" $12
    print }'
}
for h in $ALL_PIS; do check_one "$h" & done; wait
echo
echo "说明："
echo "- 型号或 CPU 频率不一样的 Pi 会拖慢 TP（大家都要等最慢的那台），见 docs/操作指南.md 第 9 节。HEAD 要用内存 4G 以上的。"
echo "- 降频标志不是 0x0：供电不足或过热降过频（0x50000 这类是开机以来发生过，0x5 这类是正在发生），这台的结果会偏慢。"
echo "- 版本是\"无\"或标了 !!：运行 scripts/setup_pi.sh。有残留进程：ssh 上去 pkill -x ggml-rpc-server（dllama 也要停掉）。"
