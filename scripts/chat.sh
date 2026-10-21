#!/bin/bash
# 用整个集群（或其中 NN 台）跑模型，直接对话。默认用改进版 TP，rpc-server 3 线程（实测 decode 最快的设置）。
# 用法：scripts/chat.sh                         交互对话（Ctrl+C 退出）
#       scripts/chat.sh "用一句话介绍瑞典"       只问一句就退出
# 环境变量：NN=4（用几台）、MODE=pp（改用流水线并行）、BUILD=stock（原版）、RPC_T=4
set -euo pipefail
source "$(dirname "$0")/lib.sh"
read -r -a W <<<"$WORKERS"
NN=${NN:-$(( ${#W[@]} + 1 ))}; NODES="$HEAD ${W[*]:0:$((NN-1))}"
case ${MODE:-tp} in tp) SM=tensor;; pp) SM=layer;; *) echo "MODE 只能是 tp 或 pp"; exit 1;; esac
RPC=""; DEV=""; i=0   # 注意：llama-cli 的设备用逗号分隔，llama-bench 用 /
for s in $NODES; do RPC+="${RPC:+,}$(ip_of $s):$RPC_PORT"; DEV+="${DEV:+,}RPC$i"; i=$((i+1)); done

for s in $NODES; do ssh_pi "$s" "pkill -x ggml-rpc-server; cd $BIN; nohup ./ggml-rpc-server -H 0.0.0.0 -p $RPC_PORT -t ${RPC_T:-3} > ~/exp/logs/rpc.log 2>&1 < /dev/null & sleep 1; pgrep -x ggml-rpc-server >/dev/null || echo '$s 的 rpc-server 启动失败'"; done
trap 'for s in $NODES; do ssh_pi "$s" "pkill -x ggml-rpc-server; true"; done' EXIT
echo "用 $NN 台 Pi（${MODE:-tp}，${BUILD:-opt}）加载模型，约 20–40 秒……"
CMD="cd $BIN; GGML_RPC_NO_SPIN=1 ./llama-cli -m $MODEL --rpc $RPC -dev $DEV -sm $SM -c 2048 --simple-io"
if [ $# -gt 0 ]; then ssh -t "$HEAD" "$CMD -st -p $(printf '%q' "$*")"
else ssh -t "$HEAD" "$CMD"; fi
