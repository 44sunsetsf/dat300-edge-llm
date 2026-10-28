# dat300-edge-llm

DAT300 第 7 组：在 Raspberry Pi 集群上用 llama.cpp 做分布式推理，比较流水线并行（PP）和张量并行（TP），找出瓶颈并优化。
模型是 Llama-3.2-3B-Instruct Q4_0。

**最终提交**：[报告 PDF](report/DAT300_Group7_Final_Report.pdf) · [幻灯片](report/slides.pdf) · [演讲稿（中英对照）](report/DAT300_Group7_Presentation_Script.pdf)

- **下次活动照着做**：[`docs/操作指南.md`](docs/操作指南.md)（从接线到出结果，一步一步写好了）
- **不用脚本、自己调参**：[`docs/手动使用改进版.md`](docs/手动使用改进版.md)（rpc-server 怎么起、主控上怎么跑、能调哪些参数）
- **每一步的耗时日志**：[`docs/计时日志.md`](docs/计时日志.md)（每台 Pi 记录每条命令的耗时，自动拆分每个 token 的时间）
- **研究结果**：[`docs/实验报告_1014.md`](docs/实验报告_1014.md)（交换机 + 4 台 Pi 实测，最新）、[`docs/RESULTS.md`](docs/RESULTS.md)（之前 2 台 Pi + Mac 模拟）
- **网络**：[`docs/网络配置.md`](docs/网络配置.md)
- **改进版 llama.cpp**：fork [`44sunsetsf/llama.cpp`](https://github.com/44sunsetsf/llama.cpp) 的 `dat300` 分支，
  预编译包在 [Releases](https://github.com/44sunsetsf/llama.cpp/releases)
  - 改进版的 commit 写在 [`LLAMA_COMMIT`](LLAMA_COMMIT)；
  - 对照用的原版写在 [`LLAMA_STOCK_COMMIT`](LLAMA_STOCK_COMMIT)。

## 目前的结论（2026-10-21，8 台设备实测，详见 [`docs/实验报告_1021.md`](docs/实验报告_1021.md) 和英文报告 [`report/main.tex`](report/main.tex)）

| Llama-3.2-3B Q4_0 | prefill | decode (tok/s) |
|---|---|---|
| 单台 Pi | 4.14 | 1.84 |
| 原版 llama.cpp TP，4 / 8 台 | 5.77 / 3.15 | 1.03 / 0.41 |
| **改进版 TP，4 台（Pi）** | **12.57** | **5.02** |
| **改进版 TP，8 台（7 Pi + RK3588）** | **16.24** | **6.34** |
| PP（任何台数的单请求） | ≈4.1 | 1.84–2.00 |

1. **单机瓶颈是内存带宽**：每生成一个 token 读一遍 1.92 GB 权重，单台 Pi 达到实测带宽的 70–85%。
2. **TP 瓶颈①：原版 4 台以上同步都经过主控中转** → 改 llama.cpp 让 Pi 之间直接 allreduce：4 台 1.03 → 2.99。
3. **TP 瓶颈②：输出层没有被切分**（tied embedding）→ `scripts/untie_output.py` 补独立的 `output.weight`，结果完全不变：2.99 → 4.85。
4. **TP 瓶颈③：8 台时主控 CPU 被 RPC 分发线程的忙等占满**（主控 94%、其他 15%，每 token 每台空等 470 ms）→ `GGML_RPC_NO_SPIN=1`：8 台 1.62 → 6.34。
5. **网络不是瓶颈**：每台资源采集显示 8 台时每台每 token 约 4 MB、最多 233 Mbit/s（链路 940 Mbit/s），而且速度变化 3.9 倍时网络量不变。
6. **PP** 单请求永远和单机一样快；在 Pi 集群上 TP 全面优于 PP。**异构**：RK3588 用 A76 编译后单机 12.3 tok/s，混用时要按速度设 `-ts`。

## 最快上手

三种角色：**笔记本**（所有命令都在这里敲）、**主控 Pi**（只有它需要模型文件，建议用 rex，模型已经在上面）、**worker Pi**（只需要程序，`setup_pi.sh` 会装好）。详见 [`docs/操作指南.md`](docs/操作指南.md)。

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
| `docs/网络配置.md` | **交换机和 IP**：10.77.0.0/24，每台 Pi 的用户名@IP 对照表，怎么登记新 Pi |
| `scripts/net/pi_static_ip.sh` | 把一台 Pi 改成固定 IP（换了交换机、没有 DHCP 时用） |
| `scripts/hosts.env.example` | Pi 列表模板。复制成 `hosts.env` 后填写，`hosts.env` 不提交 |
| `scripts/add_keys.sh` | 把控制机的 SSH 公钥装到每台 Pi |
| `scripts/setup_pi.sh` | 并行安装改进版和原版 llama.cpp（`--model` 准备模型，`--download-only` 只下载安装包） |
| `scripts/monitor.sh`、`tools/mon.c`、`scripts/analyze_mon.py` | 每台设备的 CPU / 内存 / 网络包采集（run_bench 默认开启）和按阶段分析 |
| `tools/membw.c` | 内存带宽测试（设备性能指标） |
| `scripts/check_cluster.sh` | 体检：型号、系统、频率、内存、温度、降频、网口、版本、残留进程、ping |
| `scripts/chat.sh` | 用集群直接对话（默认 TP + 改进版 + 3 线程） |
| `scripts/run_bench.sh` | 测一组：速度、每 token 流量、CPU、温度。参数见脚本开头注释 |
| `scripts/exp/session_8pi.sh` | 下次活动的实验清单（阶段 A/B/C，可以中断后接着跑） |
| `scripts/exp/netem.sh` | 给 Pi 加网络延迟（需要 sudo 密码） |
| `scripts/exp/mac_sim.sh` | 在 Mac 上用 Docker 模拟 N 台集群 |
| `scripts/summarize.py` | 把 `logs/` 里的结果汇总成表 |
| `scripts/analyze_trace.py` | 分析计时日志：每个 token 的计算 / 同步 / 等待各占多少 |
| `scripts/untie_output.py` | 给模型补独立的输出层，TP 时输出层按台数切分（4 台 +62%，结果不变）。`setup_pi.sh --model` 自动调用 |
| `scripts/make_fast_model.sh` | 生成快速模型（输出层改成 Q4_0，可选） |
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
