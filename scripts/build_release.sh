#!/bin/bash
# 在 Mac 上用 Docker（linux/arm64）编译 Pi 用的程序，可选发布成 GitHub Release。
# 默认按 Debian 13 编译；DISTRO=bookworm 编译 Debian 12 兼容版（文件名多一个 -bookworm）。两种都要发布。
# 一般不需要自己跑：Release 已经发布好了，setup_pi.sh 会直接下载。只有改了 llama.cpp 代码才需要。
#
# 用法：scripts/build_release.sh [--publish] [COMMIT]     （COMMIT 默认是 LLAMA_COMMIT 里的改进版）
#   需要在本仓库旁边 clone fork：git clone -b dat300 https://github.com/44sunsetsf/llama.cpp ../llama.cpp-dat300
#   （或用 LLAMA_SRC=路径 指定）。其他 commit 会在 git worktree ../llama.cpp-dat300-<短哈希> 里编译。
# 产物：dist/llama-<短哈希>-linux-arm64.tar.gz，解压后是 build/bin/{llama-bench,llama-batched-bench,llama-cli,llama-server,llama-perplexity,llama-quantize,ggml-rpc-server,VERSION}
# M 系列 Mac 上约 1 分钟。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
PUBLISH=0; [ "${1:-}" = --publish ] && { PUBLISH=1; shift; }
SRC=$(cd "${LLAMA_SRC:-../llama.cpp-dat300}" && pwd)
SHA=$(git -C "$SRC" rev-parse "${1:-$LLAMA_COMMIT}"); SHORT=${SHA:0:7}
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$SHA" ]; then
  WT="$SRC-$SHORT"; [ -d "$WT" ] || git -C "$SRC" worktree add -q --detach "$WT" "$SHA"; SRC="$WT"
fi
DIRTY=$(git -C "$SRC" status --porcelain --untracked-files=no | head -1)
DISTRO=${DISTRO:-trixie}; SUFFIX=""; [ "$DISTRO" = trixie ] || SUFFIX="-$DISTRO"
# MCPU：目标 CPU。默认 cortex-a72（树莓派 4/400）；RK3588 这类 A76 大核的板子用 MCPU=cortex-a76（支持点积指令，快很多），文件名多一个 -cortex-a76
MCPU=${MCPU:-cortex-a72}; [ "$MCPU" = cortex-a72 ] || SUFFIX="$SUFFIX-$MCPU"
BDIR=build-release-$DISTRO${MCPU#cortex-a72}
NAME=llama-$SHORT${DIRTY:+-dirty}-linux-arm64$SUFFIX
IMG=dat300-build-$DISTRO
TARGETS="llama-bench llama-batched-bench llama-cli llama-server llama-perplexity llama-quantize ggml-rpc-server"
docker build -q --platform linux/arm64 --build-arg BASE=debian:$DISTRO -t $IMG docker >/dev/null

# 静态链接 llama/ggml 库（不需要 LD_LIBRARY_PATH）；默认 -mcpu=cortex-a72，和 Pi 本机编译的指令集一致
docker run --rm --platform linux/arm64 -v "$SRC":/src -w /src $IMG bash -c "
  set -e
  cmake -B $BDIR -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF -DLLAMA_OPENSSL=OFF -DGGML_NATIVE=OFF \
    -DCMAKE_C_FLAGS=-mcpu=$MCPU -DCMAKE_CXX_FLAGS=-mcpu=$MCPU >/dev/null
  cmake --build $BDIR -j\$(nproc) --target $TARGETS | tail -1"

rm -rf dist/stage; mkdir -p dist/stage/build/bin
for b in $TARGETS; do cp "$SRC/$BDIR/bin/$b" dist/stage/build/bin/; done
echo "$SHA${DIRTY:+ (dirty)}" > dist/stage/build/bin/VERSION
COPYFILE_DISABLE=1 tar --no-xattrs -C dist/stage -czf "dist/$NAME.tar.gz" build && rm -rf dist/stage
echo "已生成 dist/$NAME.tar.gz（$(du -h "dist/$NAME.tar.gz" | cut -f1)）"

if [ $PUBLISH = 1 ]; then
  [ -z "$DIRTY" ] || { echo "源码有未提交的改动，先 commit 并 push 再发布"; exit 1; }
  TAG=dat300-$SHORT
  gh release view "$TAG" -R "$LLAMA_FORK" >/dev/null 2>&1 \
    || gh release create "$TAG" -R "$LLAMA_FORK" --target "$SHA" --title "${TAG}（Raspberry Pi 4/400，64 位 Debian 12/13）" \
         --notes "commit $SHA 的 arm64 静态编译版，适用于 Raspberry Pi 4/400（64 位 Debian 12 或 13）。由 dat300-edge-llm/scripts/build_release.sh 生成。"
  gh release upload "$TAG" "dist/$NAME.tar.gz" -R "$LLAMA_FORK" --clobber
  echo "已发布 $TAG"
fi
