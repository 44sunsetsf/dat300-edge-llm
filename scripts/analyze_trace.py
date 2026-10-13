#!/usr/bin/env python3
"""分析 rpc-server 的计时日志（GGML_RPC_TRACE 生成的 CSV），把每个 token 的时间拆开。

用法：python3 scripts/analyze_trace.py 日志1.csv [日志2.csv ...]
     一般是 python3 scripts/analyze_trace.py logs/trace/<某次运行>/*.csv（每台 Pi 一个文件）

日志每一行是 rpc-server 处理的一条命令：
  start_us   命令开始的时间（微秒，系统时钟。不同 Pi 的时钟不一定对齐，跨机器比较绝对时间要小心）
  idle_us    处理这条命令之前空等了多久（在等主控发下一条命令）
  dur_us     这条命令花了多久（接收数据 + 执行 + 回复）
  cmd        命令名：
               GRAPH_COMPUTE / GRAPH_RECOMPUTE  计算一段子图（RECOMPUTE = 重复用已缓存的图）
               COMM_ALLREDUCE                   和其他 Pi 直接做 allreduce（同步）
               SET_TENSOR / GET_TENSOR          主控发来输入 / 取走结果（例如 logits）
  detail     附加信息。COMM_ALLREDUCE 的 detail 里有：
               wait_compute_us  等自己这边的计算完成（CPU 上一般是 0）
               exchange_us      网络交换，包括等对方 Pi 算完（对方慢，这里就长）
               local_us         本地拷贝 + 加法

切分 token 的规则：每个 token（或者每批 prefill）开头，主控都会先发一串 SET_TENSOR（输入）。
所以"计算/同步命令之后的第一个 SET_TENSOR"就是新一段的开始。

输出：
  1. 每台 Pi 平均每个 decode token 的时间拆分（终端打印）
  2. <第一个日志所在目录>/segments.csv：每台 Pi、每一段的明细，方便自己用 Excel/pandas 分析
  3. <同目录>/allreduce.csv：每次 allreduce 的明细（第几段、第几次、各阶段耗时），可以按台对比找出慢的 Pi
"""
import csv, os, re, sys
from collections import defaultdict

COMPUTE = {"GRAPH_COMPUTE", "GRAPH_RECOMPUTE"}
XFER = {"SET_TENSOR", "SET_TENSOR_2D", "GET_TENSOR", "GET_TENSOR_2D", "SET_TENSOR_HASH", "COPY_TENSOR"}


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for r in csv.DictReader(f):
            try:
                r["start_us"], r["idle_us"], r["dur_us"] = int(r["start_us"]), int(r["idle_us"]), int(r["dur_us"])
            except (KeyError, ValueError, TypeError):
                continue  # 不完整的行（比如进程被杀时的最后一行）
            r["kv"] = dict(re.findall(r"(\w+)=(\d+)", r.get("detail") or ""))
            rows.append(r)
    return rows


def segments(rows):
    """按"计算/同步之后的第一个 SET_TENSOR"切段。只保留含有计算的段。"""
    segs, cur, seen_work = [], [], False
    for r in rows:
        if r["cmd"].startswith("SET_TENSOR") and seen_work:
            segs.append(cur)
            cur, seen_work = [], False
        cur.append(r)
        if r["cmd"] in COMPUTE or r["cmd"] == "COMM_ALLREDUCE":
            seen_work = True
    if seen_work:
        segs.append(cur)
    return [s for s in segs if any(r["cmd"] in COMPUTE for r in s)]


def summarize(seg, next_start):
    s = defaultdict(int)
    s["start_us"] = seg[0]["start_us"]
    end = next_start if next_start else seg[-1]["start_us"] + seg[-1]["dur_us"]
    s["wall_us"] = end - seg[0]["start_us"]
    for i, r in enumerate(seg):
        c, d = r["cmd"], r["dur_us"]
        if i > 0:
            s["idle_us"] += r["idle_us"]
        if c in COMPUTE:
            s["compute_us"] += d
            s["n_compute"] += 1
        elif c == "COMM_ALLREDUCE":
            s["allreduce_us"] += d
            s["n_allreduce"] += 1
            for k in ("wait_compute_us", "exchange_us", "local_us"):
                s["ar_" + k] += int(r["kv"].get(k, 0))
            s["ar_bytes"] = int(r["kv"].get("bytes", 0))
        elif c in XFER:
            s["xfer_us"] += d
            s["xfer_bytes"] += int(r["kv"].get("bytes", 0))
        else:
            s["other_us"] += d
    # 段末尾到下一段开始之间的空档（主控在采样、取 logits、准备下一个 token），算作 idle
    s["idle_us"] += max(0, s["wall_us"] - sum(r["dur_us"] for r in seg) - sum(r["idle_us"] for r in seg[1:]))
    return s


def main():
    paths = [p for p in sys.argv[1:] if os.path.basename(p) not in ("segments.csv", "allreduce.csv")]   # 跳过本脚本自己的输出
    if not paths:
        print(__doc__)
        sys.exit(1)
    out_dir = os.path.dirname(os.path.abspath(paths[0]))
    seg_rows, ar_rows = [], []
    print("每台 Pi：平均每个 decode token 的时间拆分（单位 ms；decode = 每次 allreduce 字节数最小的那些段）\n")
    print(f"{'节点':<22}{'token数':>7}{'总时间':>9}{'计算':>9}{'同步':>9}{' 其中网络':>9}{' 本地加':>8}{'收发数据':>9}{'空等主控':>9}{'同步次数':>9}")
    for path in paths:
        node = os.path.splitext(os.path.basename(path))[0]
        segs = segments(load(path))
        if not segs:
            print(f"{node:<22}（没有找到计算段）")
            continue
        sums = [summarize(seg, segs[i + 1][0]["start_us"] if i + 1 < len(segs) else None) for i, seg in enumerate(segs)]
        for i, (seg, s) in enumerate(zip(segs, sums)):
            seg_rows.append({"node": node, "segment": i, **{k: s[k] for k in (
                "start_us", "wall_us", "compute_us", "n_compute", "allreduce_us", "n_allreduce", "ar_bytes",
                "ar_wait_compute_us", "ar_exchange_us", "ar_local_us", "xfer_us", "xfer_bytes", "idle_us", "other_us")}})
            j = 0
            for r in seg:
                if r["cmd"] == "COMM_ALLREDUCE":
                    ar_rows.append({"node": node, "segment": i, "index": j, "start_us": r["start_us"], "dur_us": r["dur_us"],
                                    **{k: int(r["kv"].get(k, 0)) for k in ("bytes", "wait_compute_us", "exchange_us", "local_us")}})
                    j += 1
        # decode 段：allreduce 字节数最小（每次只算 1 个 token）
        with_ar = [s for s in sums if s["n_allreduce"] > 0]
        min_b = min((s["ar_bytes"] for s in with_ar), default=0)
        dec = [s for s in (with_ar or sums) if s["ar_bytes"] == min_b]
        # 两次测试之间的准备时间会被算进某个 token 的"空等"里：去掉总时间超过中位数 1.5 倍的段
        med = sorted(s["wall_us"] for s in dec)[len(dec) // 2]
        dec = [s for s in dec if s["wall_us"] <= 1.5 * med]
        n = len(dec)
        avg = lambda k: sum(s[k] for s in dec) / n / 1000
        print(f"{node:<22}{n:>7}{avg('wall_us'):>9.1f}{avg('compute_us'):>9.1f}{avg('allreduce_us'):>9.1f}"
              f"{avg('ar_exchange_us'):>9.1f}{avg('ar_local_us'):>8.1f}{avg('xfer_us'):>9.1f}{avg('idle_us'):>9.1f}"
              f"{sum(s['n_allreduce'] for s in dec) / n:>9.0f}")
    for name, rows in (("segments.csv", seg_rows), ("allreduce.csv", ar_rows)):
        if rows:
            with open(os.path.join(out_dir, name), "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)
    print(f"""
说明：
- 总时间 ≈ 计算 + 同步 + 收发数据 + 空等主控。1000 ÷ 总时间 ≈ decode 速度（tok/s）。
- 同步里的"网络"包括等对方 Pi 算完：如果某台 Pi 的网络时间明显比别人短，说明大家都在等它（它最慢）。
- 空等主控：rpc-server 没事做、在等主控发命令的时间（主控在采样、取 logits、调度）。
明细已写到 {os.path.join(out_dir, 'segments.csv')} 和 allreduce.csv。""")


if __name__ == "__main__":
    main()
