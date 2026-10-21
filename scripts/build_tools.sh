#!/bin/bash
# 在笔记本上用 Docker 把 tools/mon.c 静态编译成 arm64 程序 tools/mon-arm64（树莓派和 RK3588 都能直接运行）。
set -euo pipefail
cd "$(dirname "$0")/.."
docker run --rm --platform linux/arm64 -v "$PWD/tools":/t -w /t dat300-build-trixie gcc -O2 -static -o mon-arm64 mon.c
ls -l tools/mon-arm64
