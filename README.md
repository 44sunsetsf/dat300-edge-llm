# dat300-edge-llm

DAT300 第 7 组：在 Raspberry Pi 集群上用 llama.cpp 做分布式推理，比较流水线并行（PP）和张量并行（TP），找出瓶颈并优化。
模型是 Llama-3.2-3B-Instruct Q4_0。

- **下次活动照着做**：[`docs/操作指南.md`](docs/操作指南.md)（从接线到出结果，一步一步写好了）
- **不用脚本、自己调参**：[`docs/手动使用改进版.md`](docs/手动使用改进版.md)（rpc-server 怎么起、主控上怎么跑、能调哪些参数）
- **每一步的耗时日志**：[`docs/计时日志.md`](docs/计时日志.md)（每台 Pi 记录每条命令的耗时，自动拆分每个 token 的时间）
- **研究结果**：[`docs/RESULTS.md`](docs/RESULTS.md)
- **改进版 llama.cpp**：fork [`44sunsetsf/llama.cpp`](https://github.com/44sunsetsf/llama.cpp) 的 `dat300` 分支，
  预编译包在 [Releases](https://github.com/44sunsetsf/llama.cpp/releases)
  - 改进版的 commit 写在 [`LLAMA_COMMIT`](LLAMA_COMMIT)；
  - 对照用的原版写在 [`LLAMA_STOCK_COMMIT`](LLAMA_STOCK_COMMIT)。

## 目前的结论（2 台 Pi 实测 + Mac 上模拟 8 台）

1. 单台 Pi 的 decode 受**内存带宽**限制（1.85 tok/s）；网络带宽不是瓶颈。
2. TP 的另一个瓶颈是**同步次数 × 每次的延迟**，每个 token 同步 56 次。原版 llama.cpp 只有在恰好 2 台时才让 Pi 之间直接交换数据，4 台和 8 台时全部经过主控中转。模拟 8 台时，每个 token 有 4164 次串行网络延迟。
3. 2 台时计算占约 90%，其中**输出层就占 27%**：这个模型的输出层是 Q6_K，比其他层的 Q4_0 更大、也更慢。
4. 我们的优化：
   - **改代码**（fork 的 `dat300` 分支）：任意 2/4/8/16 台之间直接 allreduce，小数据直接在内存里相加，修复了 8 台初始化可能卡死的问题。模拟 8 台时串行延迟次数少 19 倍；可选的 all-gather 算法再少 4 倍，待真机验证。
   - **调参数**：decode 时 rpc-server 用 `-t 3`，2 台 TP 从 2.31 提到 2.93 tok/s。
   - **快速模型**（可选）：输出层改成 Q4_0，再快 9%（2.93 → 3.19），困惑度只差 0.6%。
5. PP 单个请求永远不比单台快，它的用处是装下单台装不下的大模型。

## 最快上手

三种角色：**笔记本**（所有命令都在这里敲）、**主控 Pi**（只有它需要模型文件，建议用 rex，原模型和快速模型都在上面）、**worker Pi**（只需要程序，`setup_pi.sh` 会装好）。详见 [`docs/操作指南.md`](docs/操作指南.md)。

以下命令都【在笔记本上】、本仓库目录下运行：

```bash
cp scripts/hosts.env.example scripts/hosts.env   # 填写 HEAD 和 WORKERS 的 用户@IP
scripts/add_keys.sh                              # 免密登录（每台输一次密码）
scripts/setup_pi.sh --model                      # 所有 Pi 并行安装，约 1 分钟
scripts/check_cluster.sh                         # 体检，没有 !! 再继续
scripts/chat.sh "你好"                           # 整个集群一起跑模型
scripts/exp/session_8pi.sh A                     # 核心验证实验
python3 scripts/summarize.py                     # 结果表
```

## 文件说明

| 路径 | 作用 |
|---|---|
| `scripts/hosts.env.example` | Pi 列表模板。复制成 `hosts.env` 后填写，`hosts.env` 不提交 |
| `scripts/add_keys.sh` | 把控制机的 SSH 公钥装到每台 Pi |
| `scripts/setup_pi.sh` | 并行安装改进版和原版 llama.cpp（`--model` 准备模型，`--download-only` 只下载安装包） |
| `scripts/check_cluster.sh` | 体检：型号、系统、频率、内存、温度、降频、网口、版本、残留进程、ping |
| `scripts/chat.sh` | 用集群直接对话（默认 TP + 改进版 + 3 线程） |
| `scripts/run_bench.sh` | 测一组：速度、每 token 流量、CPU、温度。参数见脚本开头注释 |
| `scripts/exp/session_8pi.sh` | 下次活动的实验清单（阶段 A/B/C，可以中断后接着跑） |
| `scripts/exp/netem.sh` | 给 Pi 加网络延迟（需要 sudo 密码） |
| `scripts/exp/mac_sim.sh` | 在 Mac 上用 Docker 模拟 N 台集群 |
| `scripts/summarize.py` | 把 `logs/` 里的结果汇总成表 |
| `scripts/analyze_trace.py` | 分析计时日志：每个 token 的计算 / 同步 / 等待各占多少 |
| `scripts/make_fast_model.sh` | 生成快速模型（输出层改成 Q4_0，+9%） |
| `scripts/build_release.sh` | 改了 llama.cpp 代码后，在 Mac 上用 Docker 重新编译并发布（约 1 分钟） |
| `docs/` | 操作指南、研究结果、进度 |
| `logs/` | 所有原始日志 |

## 改 llama.cpp 代码的流程

```bash
git clone -b dat300 https://github.com/44sunsetsf/llama.cpp ../llama.cpp-dat300
# 改代码，commit，push 到 dat300 分支
scripts/build_release.sh --publish                     # Debian 13 版
DISTRO=bookworm scripts/build_release.sh --publish     # Debian 12 兼容版
# 把新 commit 写进 LLAMA_COMMIT，再运行 scripts/setup_pi.sh
```

编译需要 Docker（Mac 上开 Docker Desktop）。不需要在 Pi 上编译。
