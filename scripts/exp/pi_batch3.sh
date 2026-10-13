#!/bin/bash
# Batch 3: rpc-server thread count for TP (patched build).
set -uo pipefail
cd "$(dirname "$0")/../.."
run() { local tag=$1; shift; [ -f "logs/.done_$tag" ] && return; env "$@" && touch "logs/.done_$tag"; }
OPT="BIN=~/llama.cpp/build-opt/bin"
run b3_tp_opt_t3 TAG=b3_opt_t3 RPC_T=3 "$OPT" scripts/run_bench.sh tp 2
run b3_tp_opt_t2 TAG=b3_opt_t2 RPC_T=2 "$OPT" scripts/run_bench.sh tp 2
