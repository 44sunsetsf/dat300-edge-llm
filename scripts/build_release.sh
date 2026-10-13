#!/bin/bash
# Build Pi binaries on the Mac (Docker, linux/arm64, Debian 13 like the Pis) and optionally publish them.
# Usage: scripts/build_release.sh [--publish] [LLAMA_SRC]
#   LLAMA_SRC: llama.cpp checkout (default: ../llama.cpp-dat300 next to this repo)
#   --publish: upload dist/<name>.tar.gz as a GitHub release on $LLAMA_FORK (needs gh login)
# Output: dist/llama-<shortsha>-linux-arm64.tar.gz containing build/bin/* (static libs, -mcpu=cortex-a72)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
PUBLISH=0; [ "${1:-}" = --publish ] && { PUBLISH=1; shift; }
SRC=$(cd "${1:-../llama.cpp-dat300}" && pwd)
SHA=$(git -C "$SRC" rev-parse HEAD); SHORT=${SHA:0:7}
DIRTY=$(git -C "$SRC" status --porcelain --untracked-files=no | head -1)
NAME=llama-$SHORT${DIRTY:+-dirty}-linux-arm64
docker image inspect dat300-build >/dev/null 2>&1 || docker build --platform linux/arm64 -t dat300-build docker

docker run --rm --platform linux/arm64 -v "$SRC":/src -w /src dat300-build bash -c '
  set -e
  cmake -B build-linux-arm64 -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF -DLLAMA_OPENSSL=OFF -DGGML_NATIVE=OFF \
    -DCMAKE_C_FLAGS="-mcpu=cortex-a72" -DCMAKE_CXX_FLAGS="-mcpu=cortex-a72" >/dev/null
  cmake --build build-linux-arm64 -j"$(nproc)" --target llama-bench llama-cli llama-server llama-perplexity ggml-rpc-server'

mkdir -p dist; rm -rf dist/stage; mkdir -p dist/stage/build/bin
for b in llama-bench llama-cli llama-server llama-perplexity ggml-rpc-server; do cp "$SRC/build-linux-arm64/bin/$b" dist/stage/build/bin/; done
echo "$SHA${DIRTY:+ (dirty)}" > dist/stage/build/bin/VERSION
COPYFILE_DISABLE=1 tar --no-xattrs -C dist/stage -czf "dist/$NAME.tar.gz" build && rm -rf dist/stage
echo "built dist/$NAME.tar.gz ($(du -h "dist/$NAME.tar.gz" | cut -f1))"

if [ $PUBLISH = 1 ]; then
  [ -z "$DIRTY" ] || { echo "refusing to publish a dirty tree: commit and push first"; exit 1; }
  TAG=dat300-$SHORT
  gh release view "$TAG" -R "$LLAMA_FORK" >/dev/null 2>&1 \
    || gh release create "$TAG" -R "$LLAMA_FORK" --target "$SHA" --title "$TAG (Pi 4/400 arm64 binaries)" \
         --notes "Static arm64 build of $SHA for Raspberry Pi 4/400 (Debian 13). Built by dat300-edge-llm/scripts/build_release.sh."
  gh release upload "$TAG" "dist/$NAME.tar.gz" -R "$LLAMA_FORK" --clobber
  echo "published $TAG"
fi
