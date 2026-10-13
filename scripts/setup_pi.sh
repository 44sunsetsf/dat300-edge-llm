#!/bin/bash
# Install llama.cpp (pinned commit from LLAMA_COMMIT) on one or more Pis, in parallel.
# Usage: scripts/setup_pi.sh [--native] [--model] [user@ip ...]     (default hosts: HEAD + WORKERS from hosts.env)
#   default : copy prebuilt static binaries (dist/ tarball from build_release.sh, else the GitHub release) -> ~1 min
#   --native: git clone the fork at the pinned commit and build on the Pi (needs PI_SUDO_PW for apt; ~30 min)
#   --model : also download + sha256-check the GGUF on the HEAD (workers never need it: weights come via RPC)
# Result on every Pi: ~/llama.cpp/build/bin/{llama-bench,llama-cli,ggml-rpc-server,...} and build/bin/VERSION = commit.
# Re-runnable: hosts that already have the pinned VERSION are skipped.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NATIVE=0 WANT_MODEL=0
while [ $# -gt 0 ]; do case $1 in --native) NATIVE=1;; --model) WANT_MODEL=1;; *) break;; esac; shift; done
HOSTS=${*:-"$HEAD $WORKERS"}
SHORT=${LLAMA_COMMIT:0:7}
TARBALL="$REPO_DIR/dist/llama-$SHORT-linux-arm64.tar.gz"
URL="https://github.com/$LLAMA_FORK/releases/download/dat300-$SHORT/llama-$SHORT-linux-arm64.tar.gz"

install_fast() {   # $1 = user@ip
  if [ -f "$TARBALL" ]; then
    ssh_pi "$1" 'rm -rf ~/llama.cpp/build && mkdir -p ~/llama.cpp && tar -xz -C ~/llama.cpp' < "$TARBALL"
  else
    ssh_pi "$1" "rm -rf ~/llama.cpp/build && mkdir -p ~/llama.cpp && curl -fsSL '$URL' | tar -xz -C ~/llama.cpp"
  fi
}

install_native() {
  if ! ssh_pi "$1" 'command -v cmake >/dev/null && command -v ninja >/dev/null'; then
    : "${PI_SUDO_PW:?set PI_SUDO_PW to apt-get install cmake ninja-build}"
    printf '%s\n' "$PI_SUDO_PW" | ssh_pi "$1" 'sudo -S -p "" apt-get install -y cmake ninja-build git >/tmp/apt.log 2>&1 || { tail -5 /tmp/apt.log; exit 1; }'
  fi
  ssh_pi "$1" "set -e; mkdir -p ~/exp/logs
    [ -d ~/llama.cpp/.git ] || { rm -rf ~/llama.cpp; git init -q ~/llama.cpp; }
    cd ~/llama.cpp; git remote remove origin 2>/dev/null || true; git remote add origin https://github.com/$LLAMA_FORK
    git fetch -q --depth 1 origin $LLAMA_COMMIT && git checkout -q FETCH_HEAD
    cmake -B build -G Ninja -DGGML_RPC=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF > ~/exp/logs/build.log 2>&1
    cmake --build build -j4 >> ~/exp/logs/build.log 2>&1 && echo $LLAMA_COMMIT > build/bin/VERSION"
}

setup_one() {
  local h=$1
  if [ "$(ssh_pi "$h" 'cut -d" " -f1 ~/llama.cpp/build/bin/VERSION 2>/dev/null')" = "$LLAMA_COMMIT" ]; then
    echo "llama.cpp $SHORT already installed"
  elif [ $NATIVE = 1 ]; then install_native "$h" && echo "native build of $SHORT done"
  else install_fast "$h" && echo "installed prebuilt $SHORT"; fi
  ssh_pi "$h" "cd $BIN && ./llama-bench --version 2>&1 | grep -m1 version || echo 'llama-bench FAILED to run'"
}

pids=()
for h in $HOSTS; do ( setup_one "$h" 2>&1 | sed "s/^/[$h] /" ) & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || true; done

if [ $WANT_MODEL = 1 ]; then
  ssh_pi "$HEAD" "f=$MODEL; mkdir -p \$(dirname \$f)
    if [ \"\$(stat -c %s \$f 2>/dev/null)\" != $MODEL_SIZE ]; then curl -fSL -C - --retry 5 -o \$f '$MODEL_URL'; fi
    echo '$MODEL_SHA256  '\$f | sha256sum -c --quiet && echo 'model ok'" | sed "s/^/[$HEAD] /"
fi
