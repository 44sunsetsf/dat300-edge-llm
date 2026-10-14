#!/bin/bash
# 2026-10-14 实验室（交换机 + 4 台 Pi + cat）的实验清单：TP 拆输出层、PP 流水线和多请求、异构（cat）。
# 【在笔记本上】运行：scripts/exp/study_1014.sh [T|P|H|all]
# 每一项跑完在 logs/ 留标记 .done_<项目名>，中断后重新运行会跳过已完成的项；要重跑某一项就删掉它的标记。
# 需要：hosts.env = rex 主控 + finn/han/luthen；rex 上有原模型和 untied 模型（scripts/untie_output.py 生成）。
# H 部分另外用 cat（10.77.0.6），见下面 HOSTS_CAT。
set -uo pipefail
cd "$(dirname "$0")/../.."
UNTIED='~/exp/models/Llama-3.2-3B-Instruct-Q4_0-untied.gguf'
HOSTS_CAT=$(mktemp); cat > "$HOSTS_CAT" <<'EOF'
HEAD=rex@10.77.0.4
WORKERS="cat@10.77.0.6 finn@10.77.0.2 pi@10.77.0.3"
RPC_PORT=50052
EOF
run() {   # run 项目名 模式 重复次数 [环境变量...]
  local id=$1 mode=$2 reps=$3; shift 3
  [ -f "logs/.done_$id" ] && { echo "== 跳过 ${id}（已完成）"; return; }
  echo "== 开始 ${id}：$*"
  env TAG="$id" TIMEOUT=1500 "$@" scripts/run_bench.sh "$mode" "$reps" && touch "logs/.done_$id"
}
PART=${1:-all}

if [ "$PART" = T ] || [ "$PART" = all ]; then
  # TP：拆开输出层（untied）的效果，和"原版/改进版"组成 2×2 对照
  run T01_tp4_stock_untied tp 2 NN=4 RPC_T=3 BUILD=stock MODEL="$UNTIED"
  run T02_tp2_untied       tp 2 NN=2 RPC_T=3 MODEL="$UNTIED"
  run T03_tp4_untied_t4    tp 2 NN=4 RPC_T=4 MODEL="$UNTIED" TRAFFIC=0
  run T04_tp4_untied_ag    tp 2 NN=4 RPC_T=3 MODEL="$UNTIED" ENV=GGML_RPC_COMM_ALGO=ag TRAFFIC=0
  run T05_tp2_untied_trace tp 1 NN=2 RPC_T=3 MODEL="$UNTIED" TRACE=1
  run T06_single_untied    single 2 RPC_T=4 MODEL="$UNTIED"
  run T07_tp4_untied_long  tp 1 NN=4 RPC_T=3 MODEL="$UNTIED" P=512 N=128 TRAFFIC=0
  run T08_tp4_orig_long    tp 1 NN=4 RPC_T=3 P=512 N=128 TRAFFIC=0
fi

if [ "$PART" = P ] || [ "$PART" = all ]; then
  # PP ①：prompt 切块后的流水线 prefill（定性）。-ub = 每块的 token 数：128 = 整段一块（没有流水线），32 = 切成 4 块（4 台同时干活）
  # （P01–P03 是早先 prompt 512 的版本，保留作参考）
  run P01_single_p512_ub512 single 1 RPC_T=4 P=512 N=16 UB=512
  run P02_single_p512_ub128 single 1 RPC_T=4 P=512 N=16 UB=128
  run P03_pp4_p512_ub512    pp 1 NN=4 RPC_T=4 P=512 N=16 UB=512 TRAFFIC=0
  run P04_single_p128_ub32  single 1 RPC_T=4 P=128 N=8 UB=32
  run P05_pp4_p128_ub128    pp 1 NN=4 RPC_T=4 P=128 N=8 UB=128 TRAFFIC=0
  run P06_pp4_p128_ub32     pp 1 NN=4 RPC_T=4 P=128 N=8 UB=32 TRAFFIC=0
  # PP ②：同时处理多个请求的总吞吐（每个请求 32 token prompt + 生成 16 token，1/4/8 个请求）
  B="-npp 32 -ntg 16 -npl 1,4,8"
  run P11_single_batched single 1 RPC_T=4 BATCHED="$B"
  run P12_pp4_batched    pp 1 NN=4 RPC_T=4 BATCHED="$B"
  run P13_tp4_batched    tp 1 NN=4 RPC_T=4 MODEL="$UNTIED" BATCHED="$B"
  # PP ③：多请求 + 小 ubatch，让 decode 也在 4 台之间流水线起来（8 个请求、每块 2 个，4 块同时在不同的 Pi 上）
  run P14_pp4_batched_ub2 pp 1 NN=4 RPC_T=4 UB=2 BATCHED="-npp 32 -ntg 16 -npl 8"
fi

if [ "$PART" = H ] || [ "$PART" = all ]; then
  # 异构：cat（RK3588，单机 decode 12.3）和 Pi 混用。-ts 是每台分到的比例（llama-bench 用 / 分隔）
  run H01_tp2_rexcat          tp 1 HOSTS_FILE="$HOSTS_CAT" NN=2 RPC_T=4 MODEL="$UNTIED" TRAFFIC=0
  run H02_tp2_rexcat_ts14     tp 1 HOSTS_FILE="$HOSTS_CAT" NN=2 RPC_T=4 MODEL="$UNTIED" TRAFFIC=0 EXTRA="-ts 1/4"
  run H03_pp2_rexcat          pp 1 HOSTS_FILE="$HOSTS_CAT" NN=2 RPC_T=4 TRAFFIC=0
  run H04_pp2_rexcat_ts16     pp 1 HOSTS_FILE="$HOSTS_CAT" NN=2 RPC_T=4 TRAFFIC=0 EXTRA="-ts 1/6"
  run H05_tp4_cat3pi          tp 1 HOSTS_FILE="$HOSTS_CAT" NN=4 RPC_T=4 MODEL="$UNTIED" TRAFFIC=0
  run H07_pp4_cat3pi_ub32     pp 1 HOSTS_FILE="$HOSTS_CAT" NN=4 RPC_T=4 P=128 N=8 UB=32 TRAFFIC=0
  run H08_pp4_cat3pi_ts_ub32  pp 1 HOSTS_FILE="$HOSTS_CAT" NN=4 RPC_T=4 P=128 N=8 UB=32 TRAFFIC=0 EXTRA="-ts 1/12/1/1"
fi
rm -f "$HOSTS_CAT"
echo "全部完成。汇总：python3 scripts/summarize.py"
