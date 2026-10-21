#!/bin/bash
# 跑一组 N 节点测量：重启 rpc-server → 测每 token 网络流量 → 测速度（同时用 vmstat 采 CPU）→ 记录温度和降频。
#
# 用法：scripts/run_bench.sh single|pp|tp [重复次数，默认 2]
# 环境变量（都可选）：
#   NN=4           用几台：HEAD + 前 NN-1 个 WORKERS（默认全部）。single 模式固定 1 台
#   BUILD=stock    用原版（默认 opt = 我们的改进版）
#   SPIN=1         恢复主控 RPC 线程的忙等（默认关闭：GGML_RPC_NO_SPIN=1。8 台时忙等会把主控的 CPU 占满，decode 1.62 → 6.34）
#   HEAD_T=1       主控上 llama-bench 进程本身的线程数（默认等于 RPC_T）
#   RPC_T=3        rpc-server 的线程数（默认 4；single 模式下是单机的计算线程数）；RPC_T_HEAD=3 只改 HEAD 上那个 rpc-server
#   ENV="X=1 ..."  给 llama-bench 加环境变量，例如 GGML_RPC_NO_COMM=1（关闭节点间直接交换）
#   EXTRA="..."    给 llama-bench 加参数，例如 "-ts 3/2"（不均匀切分）
#   P=32 N=30      prompt 长度 / 生成 token 数
#   TRAFFIC=0      跳过流量测量（省两次加载模型的时间）
#   TAG=名字       加在日志文件名里；NETEM_MS=2 只是记录用（延迟要另外用 scripts/exp/netem.sh 加）
#   TRACE=1        开启计时日志：每台 rpc-server 记录每条命令的耗时，跑完取回到 logs/trace/<本次日志名>/，
#                  并自动运行 scripts/analyze_trace.py 拆分每个 token 的时间（会自动跳过流量测量）
#   RPC_CACHE=1    开启 rpc-server 的本地权重缓存（加载快一倍；缓存在 ~/.cache/llama.cpp/rpc，台数一变会新增一份，注意磁盘）
#   TIMEOUT=900    每次 llama-bench 的超时秒数，卡住就放弃这组
#   MON=0          关闭资源采集（默认开）：每台设备每 0.5 秒记录 CPU / 内存 / 网卡字节数和包数（scripts/monitor.sh），
#                  取回到 logs/mon/<本次日志名>/，并按 prefill / decode 阶段汇总（scripts/analyze_mon.py）
#   UB=128         llama-bench 的 -ub（一次送进模型的最大 token 数，默认 512）。PP 下 prompt 被切成多块时会流水线执行
#   BATCHED="-npp 128 -ntg 32 -npl 1,2,4,8"  改用 llama-batched-bench 测"同时处理多个请求"的总吞吐（不测流量）
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
ARGS="-m $MODEL -t ${HEAD_T:-${RPC_T:-4}}"   # HEAD_T：主控上 llama-bench 自己的线程数（多台时它只负责调度）   # single 模式下就是计算线程数；多台时主控不参与计算，这个值无影响
[ $MODE != single ] && ARGS+=" --rpc $RPC -dev $DEV -sm $SM"
ARGS+=" ${EXTRA:-}"

RPC_C=""; [ "${RPC_CACHE:-0}" = 1 ] && RPC_C="-c"   # -c：本地缓存权重，第二次起加载快一倍；但台数一变就会新增一份缓存，容易占满磁盘，所以默认关
TRACE_ENV=""; [ "${TRACE:-0}" = 1 ] && { TRACE_ENV="GGML_RPC_TRACE=\$HOME/exp/logs/trace.csv"; TRAFFIC=0; }   # -c：worker 本地缓存权重，第二次起加载快一倍（不影响速度）
# 清理残留进程，重新起 rpc-server（每组都用新进程，内存干净）
for s in $NODES; do ssh_pi "$s" 'pkill -x ggml-rpc-server; pkill -x llama-bench; pkill -x dat300-mon; true'; done
for s in $SERVERS; do
  T=${RPC_T:-4}; [ "$s" = "$HEAD" ] && T=${RPC_T_HEAD:-$T}
  # 有 A76 大核的板子（RK3588，比如 cat）：rpc-server 绑在 4 个大核上、用 4 线程（小核会拖慢；实测 8 线程比 4 大核慢 18%）
  ssh_pi "$s" "mkdir -p ~/exp/logs; cd $BIN; T=$T; P=; grep -q 'CPU part.*0xd0b' /proc/cpuinfo && { P='taskset -c 4-7'; T=4; }
    $TRACE_ENV nohup sh -c \"exec \$P ./ggml-rpc-server -H 0.0.0.0 -p $RPC_PORT -t \$T $RPC_C\" > ~/exp/logs/rpc.log 2>&1 < /dev/null &
    sleep 1; pgrep -x ggml-rpc-server >/dev/null || { echo 'rpc-server 启动失败'; tail -3 ~/exp/logs/rpc.log; }"
done

bench() { with_timeout "${TIMEOUT:-900}" ssh -o BatchMode=yes "$HEAD" "cd $BIN; $SPINENV ${ENV:-} ./llama-bench $ARGS ${UB:+-ub $UB} $*"; }
# llama-batched-bench 的 -dev 用逗号分隔
bbench() { with_timeout "${TIMEOUT:-1800}" ssh -o BatchMode=yes "$HEAD" "cd $BIN; $SPINENV ${ENV:-} ./llama-batched-bench ${ARGS//-dev $DEV/-dev ${DEV//\//,}} -c 4096 ${UB:+-ub $UB} $*"; }
SPINENV="GGML_RPC_NO_SPIN=1"; [ "${SPIN:-0}" = 1 ] && SPINENV=""
MDIR="$LOG_DIR/mon/$(basename "$OUT" .log)"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
mon_start() { [ "${MON:-1}" = 1 ] || return 0; mkdir -p "$MDIR"
  # 记录每台设备相对笔记本的时钟偏差（Pi 没有电池时钟，重启后时间会乱），analyze_mon.py 用它对齐时间戳
  echo "__head__ ${HEAD%@*}_$(ip_of $HEAD)" > "$MDIR/offsets.txt"
  for s in $NODES; do a=$(now_ms); r=$(ssh_pi "$s" 'date +%s%3N'); b=$(now_ms); echo "${s%@*}_$(ip_of $s) $(( r - (a + b) / 2 ))" >> "$MDIR/offsets.txt"; done
  # 采集器是 tools/mon-arm64（tools/mon.c 静态编译，一个常驻进程，开销可以忽略）；每次运行前推到每台设备
  for s in $NODES; do ssh_pi "$s" 'mkdir -p ~/exp/logs; cat > ~/exp/dat300-mon; chmod +x ~/exp/dat300-mon; rm -f ~/exp/logs/mon.csv
    IF=$(ip -o -4 addr show | awk "/10\\.77\\./{print \$2; exit}"); nohup ~/exp/dat300-mon ~/exp/logs/mon.csv 500 ${IF:-eth0} > /dev/null 2>&1 < /dev/null &' < "$REPO_DIR/tools/mon-arm64"; done; }
mon_stop() { [ "${MON:-1}" = 1 ] || return 0
  for s in $NODES; do ssh_pi "$s" 'pkill -x dat300-mon; true'; scp -q "$s:exp/logs/mon.csv" "$MDIR/${s%@*}_$(ip_of $s).csv" || true; done; }
# 带时间戳的 llama-bench（--progress 的每行前面加毫秒时间戳，用来切分 prefill / decode 阶段）
bench_ts() { with_timeout "${TIMEOUT:-900}" ssh -o BatchMode=yes "$HEAD" "cd $BIN; $SPINENV ${ENV:-} ./llama-bench $ARGS ${UB:+-ub $UB} --progress $* 2>&1 | while IFS= read -r l; do echo \"\$(date +%s%3N) \$l\"; done"; }
temp_all() { for s in $NODES; do ssh_pi "$s" 'if command -v vcgencmd >/dev/null; then echo -n "$(vcgencmd measure_temp | grep -oE "[0-9.]+")C,$(vcgencmd get_throttled | cut -d= -f2) "; else echo -n "$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))C,- "; fi'; done; }
net_all() { for s in $NODES; do ssh_pi "$s" "awk '/eth0/{print \$2, \$10}' /proc/net/dev"; done | tr '\n' ' '; }
traffic() { local a b; a=($(net_all)); bench "$@" >/dev/null 2>&1; b=($(net_all))
  local out=""; for k in "${!a[@]}"; do out+="$(( b[k]-a[k] )) "; done; echo "$out"; }

{
  echo "mode=$MODE sm=$SM nn=$NN build=${BUILD:-opt} reps=$REPS rpc_t=${RPC_T:-4} rpc_t_head=${RPC_T_HEAD:-${RPC_T:-4}} env='${ENV:-}' extra='${EXTRA:-}' netem_ms=${NETEM_MS:-0}"
  echo "节点：$NODES"; echo "版本：$(ssh_pi $HEAD "cat $BIN/VERSION")"
  echo "llama-bench $ARGS${UB:+ -ub $UB}"
  KB="-"
  if [ -n "${BATCHED:-}" ]; then
    echo "## 多请求吞吐（llama-batched-bench ${BATCHED}）"
    mon_start
    bbench $BATCHED 2>&1 | grep -E '^\||pipeline parallelism' || echo "llama-batched-bench 失败"
    mon_stop; [ "${MON:-1}" = 1 ] && python3 "$REPO_DIR/scripts/analyze_mon.py" "$MDIR"
    echo "温度/降频：$(temp_all)"
    echo "BATCHED_DONE mode=$MODE nn=$NN args=${BATCHED// /,}${UB:+ ub=$UB}"
    exit 0
  fi
  if [ $MODE != single ] && [ "${TRAFFIC:-1}" = 1 ]; then
    # 流量 = 只生成的运行 - 只加载的运行（减掉启动时上传权重的流量），再除以生成的 token 数
    L=($(traffic -p 1 -n 0 -r 1)); D=($(traffic -p 0 -n $N -r 1))
    line=""; for k in "${!L[@]}"; do line+="$(( (D[k]-L[k])/N/1000 )) "; done
    echo "## 每 token 流量（kB），按上面节点顺序，每台两个数：收 发"; echo "kB/token: $line"
    KB="${line%% *}/$(echo $line | cut -d' ' -f2)"   # HEAD 的 收/发
  fi
  echo "## 速度（-p $P -n $N -r ${REPS}${UB:+ -ub $UB}）"
  mon_start; mkdir -p "$MDIR"
  bench_ts -p $P -n $N -r $REPS > "$MDIR/phases.txt" 2>&1 || true
  mon_stop
  RES=$(cut -d' ' -f2- "$MDIR/phases.txt" | grep -E '^\|' || true)
  echo "$RES"
  CPU="-"
  if [ "${MON:-1}" = 1 ]; then
    echo "## 资源采集（每台设备，按阶段；CPU 忙% = 1 - 空闲；网络是这台设备网卡的收发）"
    python3 "$REPO_DIR/scripts/analyze_mon.py" "$MDIR" "$N" "$REPS"
    # RESULT 里的 cpu = decode 阶段每台的 CPU 忙%（按节点顺序）
    CPU=$(python3 - "$MDIR" $NODES <<'PY'
import csv, sys
d, nodes = sys.argv[1], sys.argv[2:]
rows = {r["node"]: r for r in csv.DictReader(open(f"{d}/mon_summary.csv")) if r["phase"] == "decode"}
print("/".join(str(round(float(rows[n.split("@")[0] + "_" + n.split("@")[1]]["cpu_busy"]))) if (n.split("@")[0] + "_" + n.split("@")[1]) in rows else "?" for n in nodes))
PY
)
    echo "decode 阶段 CPU 忙%（按节点顺序）：$CPU"
  fi
  echo "温度/降频：$(temp_all)"
  PPV=$(grep -E "pp$P " <<<"$RES" | grep -oE '[0-9.]+ ± [0-9.]+' | head -1 | cut -d' ' -f1)
  TGV=$(grep -E "tg$N " <<<"$RES" | grep -oE '[0-9.]+ ± [0-9.]+' | head -1 | cut -d' ' -f1)
  echo "RESULT mode=$MODE nn=$NN build=${BUILD:-opt} rpc_t=${RPC_T:-4} rpc_t_head=${RPC_T_HEAD:-${RPC_T:-4}} env=${ENV:+${ENV// /,}} extra=${EXTRA:+${EXTRA// /,}}${UB:+,ub=$UB} netem_ms=${NETEM_MS:-0} prefill=${PPV:-失败} decode=${TGV:-失败} head_kb=$KB cpu=$CPU"
} 2>&1 | tee "$OUT"
for s in $SERVERS; do ssh_pi "$s" 'pkill -x ggml-rpc-server; true'; done
if [ "${TRACE:-0}" = 1 ] && [ -n "$SERVERS" ]; then
  TDIR="$LOG_DIR/trace/$(basename "$OUT" .log)"; mkdir -p "$TDIR"
  for s in $SERVERS; do scp -q "$s:exp/logs/trace.csv" "$TDIR/${s%@*}_$(ip_of $s).csv"; done
  python3 "$REPO_DIR/scripts/analyze_trace.py" "$TDIR"/*.csv | tee -a "$OUT"
  echo "计时日志：${TDIR#$REPO_DIR/}/"
fi
echo "已保存 ${OUT#$REPO_DIR/}"
