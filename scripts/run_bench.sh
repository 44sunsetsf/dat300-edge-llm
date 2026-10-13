#!/bin/bash
# 跑一组 N 节点测量：重启 rpc-server → 测每 token 网络流量 → 测速度（同时用 vmstat 采 CPU）→ 记录温度和降频。
#
# 用法：scripts/run_bench.sh single|pp|tp [重复次数，默认 2]
# 环境变量（都可选）：
#   NN=4           用几台：HEAD + 前 NN-1 个 WORKERS（默认全部）。single 模式固定 1 台
#   BUILD=stock    用原版（默认 opt = 我们的改进版）
#   RPC_T=3        rpc-server 的线程数（默认 4）；RPC_T_HEAD=3 只改 HEAD 上那个 rpc-server
#   ENV="X=1 ..."  给 llama-bench 加环境变量，例如 GGML_RPC_NO_COMM=1（关闭节点间直接交换）
#   EXTRA="..."    给 llama-bench 加参数，例如 "-ts 3/2"（不均匀切分）
#   P=32 N=30      prompt 长度 / 生成 token 数
#   TRAFFIC=0      跳过流量测量（省两次加载模型的时间）
#   TAG=名字       加在日志文件名里；NETEM_MS=2 只是记录用（延迟要另外用 scripts/exp/netem.sh 加）
#   TIMEOUT=900    每次 llama-bench 的超时秒数，卡住就放弃这组
# 日志：logs/<模式>_<台数>n_<build>[_TAG]_<时间>.log，最后一行是 RESULT（scripts/summarize.py 读它）
set -euo pipefail
source "$(dirname "$0")/lib.sh"
MODE=${1:?用法：run_bench.sh single|pp|tp [重复次数]}; REPS=${2:-2}; P=${P:-32}; N=${N:-30}
case $MODE in pp) SM=layer;; tp) SM=tensor;; single) SM=none;; *) echo "模式只能是 single、pp 或 tp"; exit 1;; esac

read -r -a W <<<"$WORKERS"
if [ $MODE = single ]; then NN=1; else NN=${NN:-$(( ${#W[@]} + 1 ))}; fi
[ "$NN" -le $(( ${#W[@]} + 1 )) ] || { echo "NN=$NN 超过了 hosts.env 里的台数"; exit 1; }
NODES="$HEAD ${W[*]:0:$((NN-1))}"
[ $MODE = single ] && SERVERS="" || SERVERS="$NODES"
OUT="$LOG_DIR/${MODE}_${NN}n_${BUILD:-opt}${TAG:+_$TAG}_$(date +%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

RPC=""; DEV=""; i=0
for s in $SERVERS; do RPC+="${RPC:+,}$(ip_of $s):$RPC_PORT"; DEV+="${DEV:+/}RPC$i"; i=$((i+1)); done
ARGS="-m $MODEL -t 4"
[ $MODE != single ] && ARGS+=" --rpc $RPC -dev $DEV -sm $SM"
ARGS+=" ${EXTRA:-}"

# 清理残留进程，重新起 rpc-server（每组都用新进程，内存干净）
for s in $NODES; do ssh_pi "$s" 'pkill -x ggml-rpc-server; pkill -x llama-bench; pkill -x vmstat; true'; done
for s in $SERVERS; do
  T=${RPC_T:-4}; [ "$s" = "$HEAD" ] && T=${RPC_T_HEAD:-$T}
  ssh_pi "$s" "mkdir -p ~/exp/logs; cd $BIN; nohup ./ggml-rpc-server -H 0.0.0.0 -p $RPC_PORT -t $T > ~/exp/logs/rpc.log 2>&1 < /dev/null &
    sleep 1; pgrep -x ggml-rpc-server >/dev/null || { echo 'rpc-server 启动失败'; tail -3 ~/exp/logs/rpc.log; }"
done

bench() { with_timeout "${TIMEOUT:-900}" ssh -o BatchMode=yes "$HEAD" "cd $BIN; ${ENV:-} ./llama-bench $ARGS $*"; }
net_all() { for s in $NODES; do ssh_pi "$s" "awk '/eth0/{print \$2, \$10}' /proc/net/dev"; done | tr '\n' ' '; }
traffic() { local a b; a=($(net_all)); bench "$@" >/dev/null 2>&1; b=($(net_all))
  local out=""; for k in "${!a[@]}"; do out+="$(( b[k]-a[k] )) "; done; echo "$out"; }

{
  echo "mode=$MODE sm=$SM nn=$NN build=${BUILD:-opt} reps=$REPS rpc_t=${RPC_T:-4} rpc_t_head=${RPC_T_HEAD:-${RPC_T:-4}} env='${ENV:-}' extra='${EXTRA:-}' netem_ms=${NETEM_MS:-0}"
  echo "节点：$NODES"; echo "版本：$(ssh_pi $HEAD "cat $BIN/VERSION")"
  echo "llama-bench $ARGS"
  KB="-"
  if [ $MODE != single ] && [ "${TRAFFIC:-1}" = 1 ]; then
    # 流量 = 只生成的运行 - 只加载的运行（减掉启动时上传权重的流量），再除以生成的 token 数
    L=($(traffic -p 1 -n 0 -r 1)); D=($(traffic -p 0 -n $N -r 1))
    line=""; for k in "${!L[@]}"; do line+="$(( (D[k]-L[k])/N/1000 )) "; done
    echo "## 每 token 流量（kB），按上面节点顺序，每台两个数：收 发"; echo "kB/token: $line"
    KB="${line%% *}/$(echo $line | cut -d' ' -f2)"   # HEAD 的 收/发
  fi
  echo "## 速度（-p $P -n $N -r ${REPS}）"
  for s in $NODES; do ssh_pi "$s" 'nohup vmstat 1 > ~/exp/logs/vmstat.log 2>&1 < /dev/null &'; done
  RES=$(bench -p $P -n $N -r $REPS 2>&1 | grep -E '^\|' || true)
  echo "$RES"
  CPU=""
  for s in $NODES; do ssh_pi "$s" 'pkill -x vmstat; true'
    c=$(ssh_pi "$s" "awk 'NR>2{us+=\$13;n++}END{if(n)printf \"%.0f\", us/n}' ~/exp/logs/vmstat.log"); CPU+="${CPU:+/}$c"; done
  echo "CPU 占用 us%（按节点顺序）：$CPU"
  echo "温度/降频：$(for s in $NODES; do ssh_pi "$s" 'echo -n "$(vcgencmd measure_temp | grep -oE "[0-9.]+")C,$(vcgencmd get_throttled | cut -d= -f2) "'; done)"
  PPV=$(grep -E "pp$P " <<<"$RES" | grep -oE '[0-9.]+ ± [0-9.]+' | head -1 | cut -d' ' -f1)
  TGV=$(grep -E "tg$N " <<<"$RES" | grep -oE '[0-9.]+ ± [0-9.]+' | head -1 | cut -d' ' -f1)
  echo "RESULT mode=$MODE nn=$NN build=${BUILD:-opt} rpc_t=${RPC_T:-4} rpc_t_head=${RPC_T_HEAD:-${RPC_T:-4}} env=${ENV:+${ENV// /,}} extra=${EXTRA:+${EXTRA// /,}} netem_ms=${NETEM_MS:-0} prefill=${PPV:-失败} decode=${TGV:-失败} head_kb=$KB cpu=$CPU"
} 2>&1 | tee "$OUT"
for s in $SERVERS; do ssh_pi "$s" 'pkill -x ggml-rpc-server; true'; done
echo "已保存 ${OUT#$REPO_DIR/}"
