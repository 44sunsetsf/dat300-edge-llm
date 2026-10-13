#!/bin/bash
# N-node PP/TP benchmark: (re)starts rpc-servers, measures per-token traffic on every node, then tok/s with vmstat.
# Usage: scripts/run_bench.sh pp|tp|single [reps]
# Env:  HEAD_LOCAL=1   (pp only) head computes its share of layers + the output layer on its own CPU
#                      instead of via a local rpc-server, so logits never cross the network (uses -ngl)
#       NETEM_MS=x     (informational tag only; netem itself is set by scripts/exp/netem.sh)
#       ENV="VAR=1 .." extra env for llama-bench (e.g. GGML_RPC_NO_COMM=1)
#       EXTRA="..."    extra llama-bench args (e.g. "-ts 0.6/0.4")
#       RPC_T=4        rpc-server threads;  RPC_T_HEAD=3  threads of the rpc-server on the head only
#       P=32 N=30      prompt / generated tokens;  TAG=name  added to the log name
# Log: logs/<mode>_<nodes>n[_TAG]_<timestamp>.log
set -euo pipefail
source "$(dirname "$0")/lib.sh"
MODE=${1:?pp, tp or single}; REPS=${2:-2}; P=${P:-32}; N=${N:-30}
case $MODE in pp) SM=layer;; tp) SM=tensor;; single) SM=none;; *) echo "mode must be pp, tp or single"; exit 1;; esac

if [ $MODE = single ]; then SERVERS=""; NODES="$HEAD"
elif [ "${HEAD_LOCAL:-0}" = 1 ]; then SERVERS="$WORKERS"; NODES="$HEAD $WORKERS"
else SERVERS="$HEAD $WORKERS"; NODES="$HEAD $WORKERS"; fi
NN=$(wc -w <<<"$NODES" | tr -d ' ')
OUT="$LOG_DIR/${MODE}_${NN}n${TAG:+_$TAG}_$(date +%m%d_%H%M%S).log"

RPC=""; DEV=""; i=0
for s in $SERVERS; do RPC+="${RPC:+,}$(ip_of $s):$RPC_PORT"; DEV+="${DEV:+/}RPC$i"; i=$((i+1)); done
ARGS="-m $MODEL -t 4"
[ $MODE != single ] && ARGS+=" --rpc $RPC -dev $DEV -sm $SM"
if [ "${HEAD_LOCAL:-0}" = 1 ]; then   # first (n_layer - ngl) layers + output on the head CPU, rest split over workers
  [ $MODE = pp ] || { echo "HEAD_LOCAL=1 only works with pp"; exit 1; }
  W=$(wc -w <<<"$WORKERS" | tr -d ' '); ARGS+=" -ngl $(( ${NLAYER:-28} * W / (W+1) ))"
fi
ARGS+=" ${EXTRA:-}"

for s in $NODES; do ssh_pi "$s" 'pkill -x ggml-rpc-server; pkill -x vmstat; true'; done
for s in $SERVERS; do
  T=${RPC_T:-4}; [ "$s" = "$HEAD" ] && T=${RPC_T_HEAD:-$T}
  ssh_pi "$s" "mkdir -p ~/exp/logs; cd $BIN; LD_LIBRARY_PATH=. nohup ./ggml-rpc-server -H 0.0.0.0 -p $RPC_PORT -t $T > ~/exp/logs/rpc.log 2>&1 < /dev/null &
    sleep 1; pgrep -x ggml-rpc-server >/dev/null || { echo 'rpc-server failed'; tail -3 ~/exp/logs/rpc.log; }"
done

bench() { ssh_pi "$HEAD" "cd $BIN; LD_LIBRARY_PATH=. ${ENV:-} ./llama-bench $ARGS $*"; }
net_all() { for s in $NODES; do ssh_pi "$s" "awk '/eth0/{print \$2, \$10}' /proc/net/dev"; done | tr '\n' ' '; }
traffic() { local a b; a=($(net_all)); bench "$@" >/dev/null 2>&1; b=($(net_all))
  local out=""; for k in "${!a[@]}"; do out+="$(( b[k]-a[k] )) "; done; echo "$out"; }

{
  echo "mode=$MODE sm=$SM nodes=$NN reps=$REPS head_local=${HEAD_LOCAL:-0} rpc_t=${RPC_T:-4} rpc_t_head=${RPC_T_HEAD:-${RPC_T:-4}} env='${ENV:-}' extra='${EXTRA:-}' netem_ms=${NETEM_MS:-0}"
  echo "nodes: $NODES"; echo "version: $(ssh_pi $HEAD "cat $BIN/VERSION 2>/dev/null || git -C ~/llama.cpp rev-parse HEAD")"
  echo "llama-bench $ARGS"
  if [ $MODE != single ]; then
    L=($(traffic -p 1 -n 0 -r 1)); D=($(traffic -p 0 -n $N -r 1))
    echo "## decode traffic per token (kB), decode-only minus load-only run, rx/tx per node in order above"
    line=""; for k in "${!L[@]}"; do line+="$(( (D[k]-L[k])/N/1000 )) "; done; echo "kB/token rx tx ...: $line"
  fi
  echo "## performance (-p $P -n $N -r $REPS)"
  for s in $NODES; do ssh_pi "$s" 'nohup vmstat 1 > ~/exp/logs/vmstat.log 2>&1 < /dev/null &'; done
  bench -p $P -n $N -r $REPS 2>&1 | grep -E '^\|' || true
  for s in $NODES; do ssh_pi "$s" 'pkill -x vmstat; true'
    echo "cpu $s: $(ssh_pi "$s" "awk 'NR>2{us+=\$13;sy+=\$14;n++}END{printf \"us=%.0f sy=%.0f\", us/n, sy/n}' ~/exp/logs/vmstat.log")"; done
} 2>&1 | tee "$OUT"
for s in $SERVERS; do ssh_pi "$s" 'pkill -x ggml-rpc-server; true'; done
echo "saved ${OUT#$REPO_DIR/}"
