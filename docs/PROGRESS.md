# 进度（断线或换人接手时先读这里）

## 当前状态（2026-10-14）
- 仓库已整理好，可以直接用来做 4/8 台的活动，照 [`操作指南.md`](操作指南.md) 做即可。
- 改进版 c1212b5（`LLAMA_COMMIT`，含 N 节点 allreduce 和计时日志 GGML_RPC_TRACE）和原版 bd4eeaa（`LLAMA_STOCK_COMMIT`）都已发布到 fork 的 Releases，每个版本有两种安装包：
  - 默认版：Debian 13，gcc 14；
  - `-bookworm` 版：Debian 12 兼容版，prefill 慢约 6%，decode 一样。
- cassian@192.168.31.30（HEAD，有模型）和 rex@192.168.31.115 已经用 `setup_pi.sh` 装好两个版本，`check_cluster.sh` 全部正常。
- 用这两台把阶段 A 预演过一遍（`logs/*_A05_*`、`*_A06_*`、`*_A07_*`、`*_A10_*`），流程跑通。
- 已有结论和 8 台的预测在 [`RESULTS.md`](RESULTS.md)。

## 下一步
- 8 台活动：`session_8pi.sh A`，把结果填进 RESULTS.md 的"8 台实测"一节。
- 之后可以做的：减少每层的同步次数、降低每次同步的固定开销、TP+PP 混合（见 RESULTS.md）。

## 踩坑（写脚本时注意）
- 判断进程要用 `pgrep -x 进程名`。`pgrep -f` 会匹配到 ssh 远端 shell 自己的命令行，造成误报或死循环。
- bash 里变量后面紧跟中文全角字符（例如 `"$REPS）"`）时，会被当成变量名的一部分，要写成 `${REPS}`。
- zsh 里 `"$h:l"` 会被解释成"转小写"修饰符，要写成 `"${h}:路径"`；zsh 也不会自动拆分 `$A` 里的多个参数（脚本都用 bash，没有这个问题）。
- llama-bench 的 `-dev` 用 `/` 分隔，llama-cli 用 `,` 分隔。
- Mac 自带的编译器坏了（CommandLineTools SDK 不匹配），所有编译都放在 Docker 里做。
- 模拟 4 台及以上的 TP 时，要用 KV head 数能被台数整除的模型。Qwen-0.5B 只有 2 个 KV head，会退回慢路径。
- 两台之间直接 allreduce 的初始化：编号小的一方一直等在 accept，编号大的一方连接时最多重试 120 秒。8 个节点挤在一台 Mac 上时，10 秒不够，会死锁。
