# 公共设置，其他脚本都会 source 这个文件（所有脚本都在笔记本上运行，通过 ssh 操作 Pi）。
# 集群相关的 IP 写在 scripts/hosts.env（不提交到 git；从 hosts.env.example 复制）。
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
HOSTS_FILE=${HOSTS_FILE:-$LIB_DIR/hosts.env}   # 可以用 HOSTS_FILE=别的文件 临时换一组 Pi / 换主控
[ -f "$HOSTS_FILE" ] && source "$HOSTS_FILE"
: "${RPC_PORT:=50052}"

LLAMA_FORK=44sunsetsf/llama.cpp
LLAMA_COMMIT=$(tr -d '[:space:]' < "$REPO_DIR/LLAMA_COMMIT")              # 改进版（我们的补丁）
LLAMA_STOCK_COMMIT=$(tr -d '[:space:]' < "$REPO_DIR/LLAMA_STOCK_COMMIT")  # 原版（对照组）
# Pi 上的位置：改进版在 build/bin，原版在 build-stock/bin。用 BUILD=stock 切换到原版。
case "${BUILD:-opt}" in
  opt)   : "${BIN:=~/llama.cpp/build/bin}" ;;
  stock) : "${BIN:=~/llama.cpp/build-stock/bin}" ;;
  *) echo "BUILD 只能是 opt 或 stock" >&2; exit 1 ;;
esac

MODEL_URL=https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_0.gguf
MODEL_SIZE=1921909280
MODEL_SHA256=4d491003bf6b470e4d04233824c5c939b76d6c81974ba17a3ff207343e1d8e85
MODEL_ORIG=~/exp/models/Llama-3.2-3B-Instruct-Q4_0.gguf     # 原模型（输出层和嵌入层共用一个矩阵）
# 默认用 untied 模型：补了独立的 output.weight（scripts/untie_output.py 生成），计算结果和原模型完全一样，
# 但 TP 时输出层能按台数切分（4 台 decode 2.99 → 4.85 tok/s）。只有 HEAD 需要模型文件。
UNTIED_SIZE=2245114464
UNTIED_SHA256=7fe7d717ef7da9e98839ad472d0cd731206894905c7964a3574c9a2227f81855
: "${MODEL:=~/exp/models/Llama-3.2-3B-Instruct-Q4_0-untied.gguf}"

LOG_DIR="$REPO_DIR/logs"
ALL_PIS="$HEAD $WORKERS"
ssh_pi() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
ip_of() { echo "${1#*@}"; }
# 超时保护：with_timeout 秒数 命令...（macOS 没有 timeout 命令，用 perl 实现）
with_timeout() { perl -e 'alarm shift; exec @ARGV or die "exec failed: $!"' "$@"; }
