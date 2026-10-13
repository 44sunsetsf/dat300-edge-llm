#!/bin/bash
# 给一组 Pi 并行安装 llama.cpp 预编译程序（改进版 + 原版），可选给 HEAD 准备模型。
#
# 用法：scripts/setup_pi.sh [--model] [--download-only] [用户@IP ...]        （默认：hosts.env 里的 HEAD + WORKERS）
#   --model：检查 HEAD 上的模型；没有的话，优先从笔记本的 ../models/ 复制（局域网，快），否则让 HEAD 从 Hugging Face 下载。
#            WORKER 永远不需要模型：权重由 HEAD 通过 RPC 发过去。
#   --download-only：只把安装包下载到笔记本的 dist/（出发前在有网的地方做一次，现场不需要外网）。
#
# 装完以后每台 Pi 上：
# 64 位 Debian 13 装默认版，Debian 12 自动装 -bookworm 兼容版，32 位系统会报错（要重装系统）。
#   ~/llama.cpp/build/bin/        改进版（LLAMA_COMMIT），默认用这个
#   ~/llama.cpp/build-stock/bin/  原版（LLAMA_STOCK_COMMIT），对照组，run_bench.sh 加 BUILD=stock 使用
#   两个目录里都有 VERSION 文件，写着 commit。
# 安装包先由笔记本从 GitHub Release 下载到 dist/（只下一次），再通过 ssh 推给每台 Pi，所以 Pi 不需要能上网。
# 可以重复运行：已经装好对应版本的 Pi 会跳过。每台约 5 秒。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
WANT_MODEL=0; DL_ONLY=0
while [ $# -gt 0 ]; do case $1 in --model) WANT_MODEL=1;; --download-only) DL_ONLY=1;; *) break;; esac; shift; done
HOSTS=${*:-$ALL_PIS}
[ $DL_ONLY = 1 ] || [ -n "${HOSTS// }" ] || { echo "没有 Pi：先 cp scripts/hosts.env.example scripts/hosts.env 并填写"; exit 1; }

fetch() {   # $1 = commit，$2 = 后缀（"" 或 "-bookworm"）；保证 dist/ 里有对应的安装包，输出路径
  local short=${1:0:7}; local name="llama-$short-linux-arm64$2.tar.gz"; local f="$REPO_DIR/dist/$name"
  if [ ! -f "$f" ]; then
    mkdir -p "$REPO_DIR/dist"
    curl -fsSL -o "$f.part" "https://github.com/$LLAMA_FORK/releases/download/dat300-$short/$name" && mv "$f.part" "$f"
  fi
  echo "$f"
}

install_one() {   # $1 = 用户@IP，$2 = 目标目录名（build 或 build-stock），$3 = commit，$4 = 安装包
  # 用安装包的 sha256 判断是否已装好（同一个 commit 重新编译过也会重装）
  local want cur; want=$(shasum -a 256 "$4" | cut -c1-16)
  cur=$(ssh_pi "$1" "cat ~/llama.cpp/$2/bin/PACKAGE 2>/dev/null" || true)
  if [ "$cur" = "$want" ]; then echo "$2 已是 ${3:0:7}"; return; fi
  ssh_pi "$1" "set -e; rm -rf ~/llama.cpp/$2 /tmp/llama-x; mkdir -p ~/llama.cpp /tmp/llama-x
    tar -xzf - -C /tmp/llama-x; mv /tmp/llama-x/build ~/llama.cpp/$2; rm -rf /tmp/llama-x; echo $want > ~/llama.cpp/$2/bin/PACKAGE" < "$4"
  echo "$2 安装了 ${3:0:7}"
}

setup_one() {
  # 64 位系统才能用；glibc 低于 2.38（Debian 12）时用 -bookworm 兼容版
  local arch glibc suf=""
  read -r arch glibc < <(ssh_pi "$1" 'echo "$(uname -m) $(ldd --version | head -1 | grep -oE "[0-9]+\.[0-9]+$")"')
  [ "$arch" = aarch64 ] || { echo "错误：系统是 ${arch}（32 位），要用 Raspberry Pi Imager 重装 64 位 Raspberry Pi OS"; return 1; }
  if [ "$(printf '%s\n2.38\n' "$glibc" | sort -V | head -1)" != 2.38 ]; then suf="-bookworm"; echo "glibc ${glibc}，使用 Debian 12 兼容版"; fi
  install_one "$1" build "$LLAMA_COMMIT" "$(fetch "$LLAMA_COMMIT" "$suf")"
  install_one "$1" build-stock "$LLAMA_STOCK_COMMIT" "$(fetch "$LLAMA_STOCK_COMMIT" "$suf")"
  ssh_pi "$1" "~/llama.cpp/build/bin/llama-bench --version 2>&1 | grep -q version && echo '可以运行' || echo '错误：llama-bench 无法运行'"
}

# 先在笔记本上把安装包下载好（并行安装时就不会重复下载）
for c in "$LLAMA_COMMIT" "$LLAMA_STOCK_COMMIT"; do for suf in "" "-bookworm"; do fetch "$c" "$suf" >/dev/null; done; done
if [ $DL_ONLY = 1 ]; then ls -lh "$REPO_DIR"/dist/*.tar.gz; exit 0; fi

pids=()
for h in $HOSTS; do ( setup_one "$h" 2>&1 | sed "s/^/[$h] /" ) & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done

if [ $WANT_MODEL = 1 ]; then
  LOCAL="$REPO_DIR/../models/$(basename "$MODEL")"
  if [ "$(ssh_pi "$HEAD" "stat -c %s $MODEL 2>/dev/null" || true)" != "$MODEL_SIZE" ]; then
    ssh_pi "$HEAD" "mkdir -p \$(dirname $MODEL)"
    if [ -f "$LOCAL" ]; then echo "[$HEAD] 从笔记本复制模型（约 1.9 GB）"; scp -q "$LOCAL" "$HEAD:${MODEL#\~/}"
    else echo "[$HEAD] 从 Hugging Face 下载模型"; ssh_pi "$HEAD" "curl -fSL -C - --retry 5 -o $MODEL '$MODEL_URL'"; fi
  fi
  echo "[$HEAD] 校验模型（约 30 秒）"
  ssh_pi "$HEAD" "f=$MODEL; echo '$MODEL_SHA256  '\$f | sha256sum -c --quiet && echo '模型校验通过'" | sed "s/^/[$HEAD] /"
fi
