# 进度（断线后先读这里）

## 当前状态（2026-10-14）
- 集群：cassian@192.168.31.30（head，模型在 `~/exp/models/Llama-3.2-3B-Instruct-Q4_0.gguf`），rex@192.168.31.115（worker）。都是 Pi 400，网线接宿舍路由器。
- 两台 Pi 的 `~/llama.cpp/build/bin` 是原版 bd4eeaa 的预编译包（`setup_pi.sh` 装的）；改进版 846e5d9 放在 `~/llama.cpp/build-opt/bin`。
- `LLAMA_COMMIT` 已改成 846e5d9，Release `dat300-846e5d9` 已发布。在新 Pi 上运行 `scripts/setup_pi.sh`，装的就是改进版。
- 已完成：第 1–3 步（Mac 上 N=2/4/8 模拟、2 台 Pi 的基线 / netem / 参数测量、N 节点 allreduce 补丁）。结果在 `docs/RESULTS.md`。

## 下一步（可选）
- 借到 4 台或 8 台 Pi 时：`scripts/setup_pi.sh --model`，然后 `RPC_T=3 scripts/run_bench.sh tp`，验证 RESULTS.md 里的估算。
- 减少每层的同步次数，或降低每次同步的固定开销（见 RESULTS.md "没做、但下一步值得做"）。

## 踩坑
- 判断进程是否在运行要用 `pgrep -x`。`pgrep -f` 会匹配到等待循环自己的命令行，导致死循环。
- zsh 里 `"$h:l"` 会被解释成"转小写"修饰符，要写成 `"${h}:path"`；zsh 也不会自动拆分 `$A` 里的多个参数，要用 `${=A}`。
- Mac 自带的编译器坏了（CommandLineTools SDK 不匹配），所有编译都放在 Docker（`dat300-build` 镜像）里做。
- 模拟 4 台及以上的 TP 时，要用 KV head 数能被 N 整除的模型。Qwen-0.5B 只有 2 个 KV head，会退回经过 head 中转的慢路径。
- netem 需要 sudo。密码只通过 `PI_SUDO_PW` 环境变量传，脚本最后一定要执行 `netem.sh <host> 0` 撤掉延迟。
