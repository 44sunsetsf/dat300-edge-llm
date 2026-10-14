# 进度（断线或换人接手时先读这里）

## 当前状态（2026-10-14 凌晨）
- 改进版 a8cd154（`LLAMA_COMMIT`）和原版 bd4eeaa（`LLAMA_STOCK_COMMIT`）都已发布到 fork 的 Releases，每个版本有两种安装包：默认版（Debian 13）和 `-bookworm` 版（Debian 12）。
  - a8cd154 = N 节点 allreduce + 计时日志 + 小数据在内存里直接相加 + 可选 all-gather（`GGML_RPC_COMM_ALGO`）+ 初始化修复（监听队列 64、accept 超时）。**c1212b5 在 8 台时初始化有概率卡死，不要再用。**
- cassian@192.168.31.30 和 rex@192.168.31.115 都已装好 a8cd154 和原版。
- **推荐 rex 当主控**：原模型和快速模型（`Llama-3.2-3B-Instruct-Q4_0-embQ40.gguf`）都在 rex 的 `~/exp/models/` 里。cassian 只剩 1.6 GB 磁盘，放不下第二份模型。rex 家目录里还有组员原来的另一份模型，没有动。
- 阶段 A、B 都用这两台预演过（超过 2 台的组会自动跳过），流程正常。
- 结论、优化尝试的结果、8 台的预测都在 [`RESULTS.md`](RESULTS.md)。

## 下一步
- 8 台活动：`session_8pi.sh A`，然后 `B`，把结果填进 RESULTS.md 的"8 台实测"一节。重点看：ag 和 rd 哪个快（B01 vs A01）、计算和同步的比例（B09）、一次算多个 token 是否划算（B08）。
- 之后可以做的：减少每层的同步次数、降低每次同步的固定开销、TP+PP 混合（见 RESULTS.md）。

## 踩坑（写脚本时注意）
- 判断进程要用 `pgrep -x 进程名`。`pgrep -f` 会匹配到 ssh 远端 shell 自己的命令行，造成误报或死循环。
- bash 里变量后面紧跟中文全角字符（例如 `"$REPS）"`）时，会被当成变量名的一部分，要写成 `${REPS}`。
- zsh 里 `"$h:l"` 会被解释成"转小写"修饰符，要写成 `"${h}:路径"`；zsh 也不会自动拆分 `$A` 里的多个参数（脚本都用 bash，没有这个问题）。
- llama-bench 的 `-dev` 用 `/` 分隔，llama-cli 用 `,` 分隔。
- Mac 自带的编译器坏了（CommandLineTools SDK 不匹配），所有编译都放在 Docker 里做。
- 模拟 4 台及以上的 TP 时，要用 KV head 数能被台数整除的模型。Qwen-0.5B 只有 2 个 KV head，会退回慢路径。
- 两台之间直接 allreduce 的初始化：编号小的一方一直等在 accept，编号大的一方连接时最多重试 120 秒。8 个节点挤在一台 Mac 上时，10 秒不够，会死锁。
- rpc-server 的 `-c` 缓存按每台分到的权重切片存，台数一变就新增一份（2 台时每台约 0.8 GB），曾把 cassian 的磁盘降到 771 MB。所以脚本里默认关闭。
- 全连接初始化时，监听队列只有 1 会导致超出队列的连接请求被内核丢掉，8 个 rank 时卡死（a8cd154 已修复）。
