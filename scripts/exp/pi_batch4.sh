#!/bin/bash
# Batch 4: thread placement. The head's dispatcher busy-spins on one core, so its local rpc-server should use 3 threads.
set -uo pipefail
cd "$(dirname "$0")/../.."
run() { local tag=$1; shift; [ -f "logs/.done_$tag" ] && return; env "$@" && touch "logs/.done_$tag"; }
OPT="BIN=~/llama.cpp/build-opt/bin"
run b4_tp_opt_h3   TAG=b4_opt_h3 RPC_T_HEAD=3 "$OPT" scripts/run_bench.sh tp 2
run b4_tp_t3       TAG=b4_t3 RPC_T=3 scripts/run_bench.sh tp 2
run b4_tp_h3       TAG=b4_h3 RPC_T_HEAD=3 scripts/run_bench.sh tp 2
run b4_pp_h3       TAG=b4_h3 RPC_T_HEAD=3 scripts/run_bench.sh pp 2
