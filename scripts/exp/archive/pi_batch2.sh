#!/bin/bash
# Batch 2 on the 2 Pis: head-local PP, patched TP, and a 2 ms netem run on the worker to get serial hops per token.
# Needs PI_SUDO_PW (for tc on the worker) and the patched binaries in ~/llama.cpp/build-opt/bin.
set -uo pipefail
cd "$(dirname "$0")/../.."; source scripts/lib.sh
run() { local tag=$1; shift; [ -f "logs/.done_$tag" ] && return; env "$@" && touch "logs/.done_$tag"; }
OPT="BIN=~/llama.cpp/build-opt/bin"
run b2_pp_local TAG=b2_local HEAD_LOCAL=1 scripts/run_bench.sh pp 2
run b2_tp_opt   TAG=b2_opt "$OPT" scripts/run_bench.sh tp 2
scripts/exp/netem.sh $WORKERS 2
run b2_pp_d2       TAG=b2_d2 NETEM_MS=2 scripts/run_bench.sh pp 1
run b2_tp_d2       TAG=b2_d2 NETEM_MS=2 scripts/run_bench.sh tp 1
run b2_tp_opt_d2   TAG=b2_opt_d2 NETEM_MS=2 "$OPT" scripts/run_bench.sh tp 1
run b2_pplocal_d2  TAG=b2_local_d2 NETEM_MS=2 HEAD_LOCAL=1 scripts/run_bench.sh pp 1
scripts/exp/netem.sh $WORKERS 0
