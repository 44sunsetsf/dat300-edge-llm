#!/bin/bash
# 8 台 Pi 活动的实验清单。每一项跑完会在 logs/ 留标记，中断后重新运行会跳过已完成的项。
# 用法：scripts/exp/session_8pi.sh A|B|C|all
#   A  核心验证（约 60–80 分钟）：N=8/4/2 的 TP 改进版 vs 原版、单机基线、PP。最重要的一项排在最前面
#   B  线程数的影响（约 20 分钟）
#   C  对网络延迟的敏感度（约 30 分钟，需要 PI_SUDO_PW）：所有 Pi 加 1 ms 延迟再测，算每 token 的串行延迟次数
# 跑完运行 scripts/summarize.py 生成结果表。要重跑某一项：删掉 logs/.done_<项目名>。
set -uo pipefail
cd "$(dirname "$0")/../.."; source scripts/lib.sh
NW=$(wc -w <<<"$WORKERS" | tr -d ' ')
[ "$NW" -ge 7 ] || echo "提醒：hosts.env 里只有 $((NW+1)) 台，超过台数的项目会被跳过"
run() {   # run 项目名 [环境变量...] 模式 [重复次数]
  local id=$1; shift
  [ -f "logs/.done_$id" ] && { echo "== 跳过 ${id}（已完成）"; return; }
  local nn; nn=$(printf '%s\n' "$@" | sed -n 's/^NN=//p'); [ -n "$nn" ] && [ "$nn" -gt $((NW+1)) ] && { echo "== 跳过 ${id}（台数不够）"; return; }
  echo "== 开始 ${id}：$*"
  env TAG="$id" "$@" scripts/run_bench.sh "${MODE_ARGS[@]}" && touch "logs/.done_$id"
}
phase_A() {
  MODE_ARGS=(tp 2)
  run A01_tp8_opt_t3    NN=8 RPC_T=3
  run A02_tp8_stock_t3  NN=8 RPC_T=3 BUILD=stock TIMEOUT=1200
  run A03_tp4_opt_t3    NN=4 RPC_T=3
  run A04_tp4_stock_t3  NN=4 RPC_T=3 BUILD=stock
  run A05_tp2_opt_t3    NN=2 RPC_T=3
  run A06_tp2_stock_t3  NN=2 RPC_T=3 BUILD=stock
  MODE_ARGS=(single 2)
  run A07_single
  MODE_ARGS=(pp 2)
  run A08_pp8           NN=8
  run A09_pp4           NN=4
  run A10_pp2           NN=2
}
phase_B() {
  MODE_ARGS=(tp 2)
  run B01_tp8_opt_t4      NN=8 RPC_T=4
  run B02_tp8_opt_h3      NN=8 RPC_T=4 RPC_T_HEAD=3
  run B03_tp8_opt_t2      NN=8 RPC_T=2
  run B04_tp4_opt_t4      NN=4 RPC_T=4
}
phase_C() {
  : "${PI_SUDO_PW:?C 阶段需要 PI_SUDO_PW}"
  trap 'scripts/exp/netem.sh 0 >/dev/null' EXIT    # 不管怎么结束都撤掉延迟
  scripts/exp/netem.sh 1
  MODE_ARGS=(tp 1)
  run C01_tp8_opt_d1    NN=8 RPC_T=3 NETEM_MS=1 TRAFFIC=0
  run C02_tp8_stock_d1  NN=8 RPC_T=3 NETEM_MS=1 TRAFFIC=0 BUILD=stock TIMEOUT=1800
  run C03_tp4_opt_d1    NN=4 RPC_T=3 NETEM_MS=1 TRAFFIC=0
  run C04_tp2_opt_d1    NN=2 RPC_T=3 NETEM_MS=1 TRAFFIC=0
  MODE_ARGS=(pp 1)
  run C05_pp8_d1        NN=8 NETEM_MS=1 TRAFFIC=0
  scripts/exp/netem.sh 0
}
case ${1:-} in
  A) phase_A;; B) phase_B;; C) phase_C;; all) phase_A; phase_B; phase_C;;
  *) echo "用法：session_8pi.sh A|B|C|all"; exit 1;;
esac
python3 scripts/summarize.py
