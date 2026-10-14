#!/bin/bash
# 生成"快速模型"：只把输出层（和输入词表共用的 token_embd.weight）从 Q6_K 重新量化成 Q4_0，其他张量逐字节不变。
# 实测（2 台 Pi，改进版，3 线程）：decode 2.93 → 3.20 tok/s（+9%），单机 1.93 → 2.03（+5%）；
# 困惑度 8.08 → 8.13（+0.6%，在误差范围内）。详见 docs/RESULTS.md。
#
# 用法（在笔记本上运行）：
#   scripts/make_fast_model.sh            在 HEAD 上直接生成（HEAD 需要有原模型，并且有 1.9 GB 以上空闲磁盘；约几分钟）
#   scripts/make_fast_model.sh --local    在笔记本上用 Docker 生成（需要 ../models/ 里有原模型），再复制到 HEAD
# 生成后使用：MODEL=~/exp/models/Llama-3.2-3B-Instruct-Q4_0-embQ40.gguf scripts/run_bench.sh tp
#             （chat.sh 也一样，在前面加 MODEL=...）
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT_NAME=Llama-3.2-3B-Instruct-Q4_0-embQ40.gguf
OUT_SIZE=1820330528
OUT_SHA256=57f5e8b48c79cacf6889503507c0ce447ff786b634e79cccffcb935f0d60d18e
OUT="$(dirname "$MODEL")/$OUT_NAME"
# 原模型里有 3 个 ffn_down 是 Q4_1，保持不变；Q4_0 → Q4_0 的重新量化是逐字节不变的
QARGS="--allow-requantize --token-embedding-type q4_0 --tensor-type blk\\.0\\.ffn_down=q4_1 --tensor-type blk\\.1\\.ffn_down=q4_1 --tensor-type blk\\.10\\.ffn_down=q4_1"

check() { ssh_pi "$HEAD" "f=$OUT; [ \"\$(stat -c %s \$f 2>/dev/null)\" = $OUT_SIZE ] && echo '$OUT_SHA256  '\$f | sha256sum -c --quiet"; }
if check 2>/dev/null; then echo "[$HEAD] 快速模型已经存在并校验通过：$OUT"; exit 0; fi

if [ "${1:-}" = --local ]; then
  SRC_DIR="$REPO_DIR/../models"
  [ -f "$SRC_DIR/$(basename "$MODEL")" ] || { echo "笔记本上没有 $SRC_DIR/$(basename "$MODEL")，见 docs/操作指南.md 第 0 步"; exit 1; }
  docker build -q --platform linux/arm64 -t dat300-build-trixie "$REPO_DIR/docker" >/dev/null
  BIN_LOCAL="$REPO_DIR/dist/quant"; mkdir -p "$BIN_LOCAL"
  tar -xzf "$REPO_DIR/dist/llama-${LLAMA_COMMIT:0:7}-linux-arm64.tar.gz" -C "$BIN_LOCAL"
  echo "在笔记本上生成……"
  docker run --rm --platform linux/arm64 -v "$BIN_LOCAL/build/bin":/b:ro -v "$SRC_DIR":/m dat300-build-trixie \
    bash -c "/b/llama-quantize $QARGS /m/$(basename "$MODEL") /m/$OUT_NAME Q4_0 4 > /dev/null"
  echo "复制到 ${HEAD}（约 1.8 GB）……"; scp -q "$SRC_DIR/$OUT_NAME" "$HEAD:${OUT#\~/}"
else
  free_kb=$(ssh_pi "$HEAD" "df -k --output=avail ~ | tail -1")
  [ "$free_kb" -gt 1900000 ] || { echo "[$HEAD] 磁盘只剩 $((free_kb/1024)) MB，不够（要 1.9 GB）。可以清理空间，或者用 --local 在笔记本上生成"; exit 1; }
  echo "[$HEAD] 正在生成（几分钟）……"
  ssh_pi "$HEAD" "cd $BIN && ./llama-quantize $QARGS $MODEL $OUT Q4_0 4 > ~/exp/logs/quantize.log 2>&1 || { tail -5 ~/exp/logs/quantize.log; exit 1; }"
fi
check && echo "[$HEAD] 快速模型生成并校验通过：$OUT" || { echo "[$HEAD] 校验失败：生成的文件和预期不一致"; exit 1; }
