#!/bin/bash
# Batch 1 on the 2 Pis: baseline + cheap parameter variants. Each line is one run_bench.sh call; finished ones are skipped.
set -uo pipefail
cd "$(dirname "$0")/../.."
run() { local tag=$1; shift; [ -f "logs/.done_$tag" ] && return; env "$@" && touch "logs/.done_$tag"; }
run b1_single  TAG=b1 scripts/run_bench.sh single 2
run b1_pp      TAG=b1 scripts/run_bench.sh pp 2
run b1_tp      TAG=b1 scripts/run_bench.sh tp 2
run b1_tp_nocomm TAG=b1_nocomm ENV=GGML_RPC_NO_COMM=1 scripts/run_bench.sh tp 2
run b1_pp_local  TAG=b1_local HEAD_LOCAL=1 scripts/run_bench.sh pp 2
run b1_tp_local  TAG=b1_local HEAD_LOCAL=1 scripts/run_bench.sh tp 2
