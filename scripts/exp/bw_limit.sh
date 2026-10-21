#!/bin/bash
# 限速实验：模型加载阶段保持千兆，主控出现 "warmup generation run"（权重已加载完）时把所有设备的网卡切到 SPEED Mbps，
# 生成阶段在限速下测量，结束后恢复千兆。【在笔记本上】运行：
#   SPEED=10 scripts/exp/bw_limit.sh 测试名 [run_bench 的环境变量...]
# 例：SPEED=10 scripts/exp/bw_limit.sh L01_tp8_stock BUILD=stock NN=8 RPC_T=4 N=3
# 网卡只通告 SPEED Mbps 全双工（ethtool advertise），交换机端口随之以同样速率运行；需要每台设备的 sudo 密码（环境变量 PI_PW / CAT_PW）。
set -uo pipefail
cd "$(dirname "$0")/../.."; source scripts/lib.sh
ID=$1; shift; SPEED=${SPEED:-10}
case $SPEED in 10) ADV=0x002;; 100) ADV=0x008;; *) echo "SPEED 只能是 10 或 100"; exit 1;; esac
setspeed() {  # $1 = advertise mask
  for s in $ALL_PIS; do pw=$PI_PW; [[ $s == cat@* ]] && pw=$CAT_PW
    ssh_pi "$s" "echo '$pw' | sudo -S -p '' ethtool -s \$(ip -o -4 addr show | awk '/10\\.77\\./{print \$2; exit}') advertise $1" & done; wait; }
restore() { setspeed 0x03f; sleep 4; echo "[bw] 已恢复千兆 $(date +%T)"; }
trap restore EXIT
( env TAG="$ID" TRAFFIC=0 TIMEOUT=3000 P=0 "$@" scripts/run_bench.sh tp 1 ) &
RB=$!
# 等这次运行的 phases.txt 出现 warmup generation run
sleep 5
until ls -t logs/mon/*_"$ID"_*/phases.txt >/dev/null 2>&1 && grep -q "warmup generation run" "$(ls -td logs/mon/*_"$ID"_* | head -1)/phases.txt"; do
  kill -0 $RB 2>/dev/null || break; sleep 1; done
echo "[bw] 权重已加载，切到 ${SPEED} Mbps $(date +%T)"; setspeed $ADV; sleep 4
for s in $ALL_PIS; do ssh_pi "$s" 'cat /sys/class/net/eth0/speed 2>/dev/null' | tr '\n' ' '; done; echo "(Mbps)"
wait $RB
