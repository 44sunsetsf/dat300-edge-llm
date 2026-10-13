# dat300-edge-llm

DAT300 Group 7: distributed LLM inference (llama.cpp RPC, pipeline vs tensor parallel) on a Raspberry Pi 4/400 cluster.
Model: Llama-3.2-3B-Instruct Q4_0. llama.cpp is pinned to our fork [`44sunsetsf/llama.cpp`](https://github.com/44sunsetsf/llama.cpp),
branch `dat300` (commit in [`LLAMA_COMMIT`](LLAMA_COMMIT)).

Results and analysis: [`docs/RESULTS.md`](docs/RESULTS.md).

## Bring up new Pis (from a laptop, ~1 min)

```bash
# 1. once per Pi: passwordless SSH
ssh-copy-id user@PI_IP

# 2. list the Pis
cp scripts/hosts.env.example scripts/hosts.env   # edit HEAD and WORKERS

# 3. install llama.cpp on all Pis in parallel (prebuilt static arm64 binaries, ~5 s per Pi)
scripts/setup_pi.sh --model        # --model: download the GGUF on the HEAD only (workers never need it)
#   or: PI_SUDO_PW=... scripts/setup_pi.sh --native   # git clone + build on each Pi (~30 min)

# 4. benchmark
scripts/run_bench.sh single        # one Pi
scripts/run_bench.sh pp            # pipeline parallel over HEAD + WORKERS
scripts/run_bench.sh tp            # tensor parallel
```

Everything lands in `~/llama.cpp/build/bin` on each Pi (`VERSION` holds the commit). Logs go to `logs/`.

## Rebuilding the binaries (on a Mac with Docker)

```bash
git clone -b dat300 https://github.com/44sunsetsf/llama.cpp ../llama.cpp-dat300
scripts/build_release.sh            # ~1 min on an M-series Mac; dist/llama-<sha>-linux-arm64.tar.gz
scripts/build_release.sh --publish  # also upload as a GitHub release so Pis can fetch it without the laptop
```

Then put the new commit into `LLAMA_COMMIT` and rerun `scripts/setup_pi.sh`.

## Simulating N nodes on the Mac

```bash
scripts/exp/mac_sim.sh path/to/model.gguf "2 4 8" 2
```

This runs one Docker container per rpc-server plus a head container, adds 2 ms of netem delay, and reports tok/s,
the number of serial network hops per token (the slope), and kB per token.

## Layout

- `scripts/`: setup, benchmark and release scripts (`lib.sh` holds shared settings; `hosts.env` is local only)
- `scripts/exp/`: experiment batches
- `docs/RESULTS.md`: findings; `docs/PROGRESS.md`: status and how to resume
- `logs/`: raw logs
