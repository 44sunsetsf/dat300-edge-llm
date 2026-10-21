#!/bin/bash
# 2026-10-21 实验室 8 台设备（7 台 Pi + cat）的实验清单。所有测试都开资源采集（MON=1，默认）。
# 【在笔记本上】运行：scripts/exp/study_1021.sh [S|T|P|B|all]
# 每一项跑完在 logs/ 留标记 .done_<项目名>，中断后重新运行会跳过已完成的项。
# hosts.env 的顺序：rex（主控）finn han cassian（Pi 400）luthen jarjar crosshair（Pi 4B）cat（RK3588）
#   → NN=2/4 只用 Pi 400，NN=8 = 7 台 Pi + cat（TP 只支持 2 的幂台数）
set -uo pipefail
cd "$(dirname "$0")/../.."
UNTIED='~/exp/models/Llama-3.2-3B-Instruct-Q4_0-untied.gguf'
ORIG='~/exp/models/Llama-3.2-3B-Instruct-Q4_0.gguf'
TS8C2="-ts 1/1/1/1/1/1/1/2"   # cat 分 2 份
TS8C4="-ts 1/1/1/1/1/1/1/4"   # cat 分 4 份
run() {   # run 项目名 模式 重复次数 [环境变量...]
  local id=$1 mode=$2 reps=$3; shift 3
  [ -f "logs/.done_$id" ] && { echo "== 跳过 ${id}（已完成）"; return; }
  echo "== 开始 ${id}：$*"
  env TAG="$id" TIMEOUT=1500 TRAFFIC=0 "$@" scripts/run_bench.sh "$mode" "$reps" && touch "logs/.done_$id"
}
PART=${1:-all}

if [ "$PART" = S ] || [ "$PART" = all ]; then
  # 扩展性：TP（改进版 + untied）1/2/4 台 Pi，8 台（含 cat）；每台的 CPU / 内存 / 网络都有采集
  run S01_single         single 2 RPC_T=4 MODEL="$UNTIED"
  run S02_tp2            tp 2 NN=2 RPC_T=3 MODEL="$UNTIED"
  run S03_tp4            tp 2 NN=4 RPC_T=4 MODEL="$UNTIED"
  run S04_tp8            tp 2 NN=8 RPC_T=4 MODEL="$UNTIED"
  run S05_tp8_cat2       tp 2 NN=8 RPC_T=4 MODEL="$UNTIED" EXTRA="$TS8C2"
  run S06_tp8_cat4       tp 2 NN=8 RPC_T=4 MODEL="$UNTIED" EXTRA="$TS8C4"
  run S07_tp8_t3         tp 2 NN=8 RPC_T=3 MODEL="$UNTIED"
fi

if [ "$PART" = T ] || [ "$PART" = all ]; then
  # 8 台的对照：原版（主控中转）、原模型（输出层不切分）、ag 同步算法、计时日志
  run T01_tp8_stock      tp 1 NN=8 RPC_T=4 MODEL="$UNTIED" BUILD=stock N=16
  run T02_tp8_tied       tp 2 NN=8 RPC_T=4 MODEL="$ORIG"
  run T03_tp8_ag         tp 2 NN=8 RPC_T=4 MODEL="$UNTIED" ENV=GGML_RPC_COMM_ALGO=ag
  run T04_tp8_trace      tp 1 NN=8 RPC_T=4 MODEL="$UNTIED" TRACE=1
  run T05_tp4_trace      tp 1 NN=4 RPC_T=4 MODEL="$UNTIED" TRACE=1
fi

if [ "$PART" = P ] || [ "$PART" = all ]; then
  # PP：2/4/8 台（8 台含 cat），以及 8 台按速度加权；长 prompt 切块流水线
  run P01_pp2            pp 2 NN=2 RPC_T=4 MODEL="$ORIG"
  run P02_pp4            pp 2 NN=4 RPC_T=4 MODEL="$ORIG"
  run P03_pp8            pp 2 NN=8 RPC_T=4 MODEL="$ORIG"
  run P04_pp8_cat4       pp 2 NN=8 RPC_T=4 MODEL="$ORIG" EXTRA="$TS8C4"
  run P05_pp8_ub32       pp 1 NN=8 RPC_T=4 MODEL="$ORIG" P=128 N=8 UB=32
fi

if [ "$PART" = B ] || [ "$PART" = all ]; then
  # 多请求吞吐（每个请求 32 token prompt + 生成 16 token；1/4/8 个请求）
  B="-npp 32 -ntg 16 -npl 1,4,8"
  run B01_tp8_batched    tp 1 NN=8 RPC_T=4 MODEL="$UNTIED" BATCHED="$B"
  run B02_pp8_batched_ub2 pp 1 NN=8 RPC_T=4 MODEL="$ORIG" UB=2 BATCHED="-npp 32 -ntg 16 -npl 8"
fi
echo "全部完成。汇总：python3 scripts/summarize.py"
