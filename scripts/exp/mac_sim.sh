#!/bin/bash
# Simulate an N-node cluster on the Mac with Docker containers (one rpc-server per container + a head container).
# Measures, for PP and TP, decode tok/s with 0 and D ms of added one-way delay (tc netem on every container),
# and per-token bytes on every container. slope = (t_D - t_0)/D = serial network hops per generated token.
# Usage: scripts/exp/mac_sim.sh MODEL.gguf "1 2 4 8" [D_ms]      env: BIN_DIR (linux arm64 bins), NGEN (default 16),
#        HEAD_ENV="VAR=value" (passed to llama-bench, e.g. GGML_RPC_COMM_ALGO=ag)
set -euo pipefail
MODEL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); NS=${2:-"2 4 8"}; D=${3:-2}; NGEN=${NGEN:-16}
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR=${BIN_DIR:-$REPO_DIR/../llama.cpp-dat300/build-linux-arm64/bin}
OUT="$REPO_DIR/logs/mac_sim_$(basename "$MODEL" .gguf)_$(date +%m%d_%H%M%S).log"
NET=dat300sim; IMG=${IMG:-dat300-build-trixie}   # 和编译程序用的系统一致（Debian 13）
run() { docker run -d --rm --platform linux/arm64 --cap-add NET_ADMIN --network $NET -v "$BIN_DIR":/bin2:ro -v "$MODEL":/model.gguf:ro --name "$@" >/dev/null; }
cleanup() { docker rm -f $(docker ps -aq --filter name=dsim-) >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
netem() { for c in $(docker ps --format '{{.Names}}' --filter name=dsim-); do
  docker exec $c tc qdisc replace dev eth0 root netem delay ${1}ms 2>/dev/null || docker exec $c tc qdisc del dev eth0 root 2>/dev/null || true; done; }
bytes() { for c in $(docker ps --format '{{.Names}}' --filter name=dsim- | sort); do docker exec $c awk '/eth0/{s+=$2+$10}END{print s}' /proc/net/dev; done | paste -sd+ - | bc; }
tg() { docker exec ${HEAD_ENV:+-e "$HEAD_ENV"} dsim-head /bin2/llama-bench -m /model.gguf $1 -p 0 -n $NGEN -o jsonl 2>/dev/null |
  python3 -c 'import sys,json; print([json.loads(l) for l in sys.stdin if l.startswith("{")][-1]["avg_ts"])'; }
kb_tok() {   # marginal bytes per generated token: (bytes of -n 3*NGEN run - bytes of -n NGEN run) / (2*NGEN)
  local b0 b1 b2; b0=$(bytes); docker exec ${HEAD_ENV:+-e "$HEAD_ENV"} dsim-head /bin2/llama-bench -m /model.gguf $1 -p 0 -n $NGEN -r 1 >/dev/null 2>&1
  b1=$(bytes); docker exec ${HEAD_ENV:+-e "$HEAD_ENV"} dsim-head /bin2/llama-bench -m /model.gguf $1 -p 0 -n $((3*NGEN)) -r 1 >/dev/null 2>&1; b2=$(bytes)
  echo $(( ((b2-b1)-(b1-b0)) / (2*NGEN) / 1000 )); }
{
echo "model=$(basename "$MODEL") N=($NS) netem=${D}ms ngen=$NGEN host=$(sysctl -n hw.ncpu)cpu"
echo "N mode tg_0ms(tok/s) tg_${D}ms(tok/s) ms/tok_0 ms/tok_D hops/token(slope) kB/token(sum over all containers, rx+tx)"
for n in $NS; do
  cleanup; run dsim-head $IMG sleep infinity
  RPC=""; DEV=""
  for i in $(seq 0 $((n-1))); do
    run dsim-s$i $IMG /bin2/ggml-rpc-server -H 0.0.0.0 -p 50052 -t $(( 8/n > 0 ? 8/n : 1 ))
    RPC+="${RPC:+,}dsim-s$i:50052"; DEV+="${DEV:+/}RPC$i"
  done
  sleep 2
  for mode in layer tensor; do
    A="--rpc $RPC -dev $DEV -sm $mode -t 1"
    kb=$(kb_tok "$A")
    t0=$(tg "$A -r 2"); netem $D; tD=$(tg "$A -r 2"); netem 0
    awk -v n=$n -v m=$mode -v t0=$t0 -v tD=$tD -v D=$D -v kb=$kb 'BEGIN{
      ms0=1000/t0; msD=1000/tD; printf "%d %s %.2f %.2f %.1f %.1f %.1f %d\n", n, m, t0, tD, ms0, msD, (msD-ms0)/D, kb}'
  done
done
} 2>&1 | tee "$OUT"
echo "saved ${OUT#$REPO_DIR/}"
