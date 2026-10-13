# Shared settings, sourced by the other scripts (all run on the Mac / a laptop).
# Cluster-specific values live in scripts/hosts.env (not committed; copy hosts.env.example).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
[ -f "$LIB_DIR/hosts.env" ] && source "$LIB_DIR/hosts.env"
: "${RPC_PORT:=50052}"

LLAMA_FORK=44sunsetsf/llama.cpp
LLAMA_COMMIT=$(tr -d '[:space:]' < "$REPO_DIR/LLAMA_COMMIT")
BIN=${BIN:-'~/llama.cpp/build/bin'}   # override e.g. BIN='~/llama.cpp/build-opt/bin'

MODEL_URL=https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_0.gguf
MODEL_SIZE=1921909280
MODEL_SHA256=4d491003bf6b470e4d04233824c5c939b76d6c81974ba17a3ff207343e1d8e85
: "${MODEL:=~/exp/models/Llama-3.2-3B-Instruct-Q4_0.gguf}"

LOG_DIR="$REPO_DIR/logs"
ssh_pi() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }
ip_of() { echo "${1#*@}"; }
