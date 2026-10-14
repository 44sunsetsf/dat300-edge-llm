#!/bin/bash
# 把一台 Pi 的有线网口改成固定 IP（10.77.0.X/24），关掉 DHCP。【在笔记本上】运行：
#   scripts/net/pi_static_ip.sh 用户名@当前能连上的地址 X
# 例：scripts/net/pi_static_ip.sh pi@10.77.0.123 5      （会提示输入这台 Pi 的 sudo 密码）
# 现在交换机已经开了 DHCP 并按 MAC 分配地址（见 docs/网络配置.md），一般不需要这个脚本；
# 交换机恢复出厂设置或者换了交换机时，用它让 Pi 不依赖 DHCP。
# 原因：Pi 默认用 DHCP，网络里没有 DHCP 服务器时，NetworkManager 每 45 秒判定失败并重置网口，Pi 会时断时续。
# 原来手动配的其他地址（比如 10.0.0.x）会保留。重启后仍然有效。
set -euo pipefail
[ $# -eq 2 ] || { sed -n 2,4p "$0"; exit 1; }
ssh -t "$1" "X=$2; "'
con=$(nmcli -t -f NAME,TYPE con show | awk -F: '\''$2=="802-3-ethernet"{print $1; exit}'\'')
addrs="10.77.0.$X/24"; for a in $(nmcli -g ipv4.addresses con show "$con" | tr "," " "); do [ "$a" != "10.77.0.$X/24" ] && addrs="$addrs,$a"; done
sudo nmcli con mod "$con" ipv4.method manual ipv4.addresses "$addrs" ipv4.gateway "" ipv6.method link-local connection.autoconnect yes
echo "连接 ${con} -> ${addrs}，正在重新激活（ssh 可能会断开）"
sudo nohup nmcli con up "$con" >/dev/null 2>&1 &
sleep 1'
