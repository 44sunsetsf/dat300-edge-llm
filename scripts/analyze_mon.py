#!/usr/bin/env python3
"""分析 scripts/monitor.sh 采集的资源数据，按阶段（prefill / decode）给出每台设备的 CPU、内存、网络。

用法：python3 scripts/analyze_mon.py 目录 [每次生成的 token 数 N] [重复次数 R]
目录里：每台设备一个 <用户>_<IP>.csv（monitor.sh 的输出），以及 phases.txt（主控上 llama-bench --progress
的输出，每行前面是毫秒时间戳）。没有 phases.txt 时（比如 llama-batched-bench）统计整个运行期间。
输出：终端表格 + 目录里的 mon_summary.csv。
各台设备的时钟在实验前从笔记本同步过（误差约 1 秒），所以阶段的时间窗口两端各收缩 0.5 秒。
"""
import csv, glob, os, sys

d = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 0
R = int(sys.argv[3]) if len(sys.argv) > 3 else 0
HZ = 100  # /proc/stat 的单位 jiffies = 1/100 秒（Linux 默认 USER_HZ）

# 每台设备相对笔记本的时钟偏差（毫秒），由 run_bench.sh 在开始采集时测量；所有时间戳都减去它，换算成笔记本时间
OFF, HEADKEY = {}, None
if os.path.exists(os.path.join(d, "offsets.txt")):
    for line in open(os.path.join(d, "offsets.txt")):
        k, v = line.split()
        if k == "__head__":
            HEADKEY = v
        else:
            OFF[k] = int(v)

def windows():
    p = os.path.join(d, "phases.txt")
    if not os.path.exists(p):
        return None
    ev = []
    for line in open(p, errors="replace"):
        parts = line.rstrip("\n").split(" ", 1)
        if len(parts) == 2 and parts[0].isdigit() and "llama-bench:" in parts[1]:
            ev.append((int(parts[0]) - OFF.get(HEADKEY, 0), parts[1]))
    ts_all = [int(l.split(" ", 1)[0]) - OFF.get(HEADKEY, 0) for l in open(p, errors="replace") if l.split(" ", 1)[0].isdigit()]
    end = max(ts_all) if ts_all else None
    w = {}
    pr = [t for t, s in ev if "prompt run 1/" in s]
    gr = [t for t, s in ev if "generation run 1/" in s]
    st2 = [t for t, s in ev if "benchmark 2/" in s and "starting" in s]
    if pr:
        w["prefill"] = (pr[0], st2[0] if st2 and st2[0] > pr[0] else (gr[0] if gr else end))
    if gr:
        w["decode"] = (gr[0], end)
    return w

def load(f):
    rows = []
    for r in csv.DictReader(open(f)):
        try:
            rows.append({k: int(v) for k, v in r.items()})
        except (ValueError, TypeError):
            pass  # 被中断时最后一行可能不完整
    return rows

def at(rows, t):
    """时间 t 附近的一行（取第一个 ts >= t 的样本）。"""
    for r in rows:
        if r["ts_ms"] >= t:
            return r
    return rows[-1]

def stats(rows, t0, t1):
    t0 += 500; t1 -= 500
    seg = [r for r in rows if t0 <= r["ts_ms"] <= t1]
    if len(seg) < 2:
        return None
    a, b = seg[0], seg[-1]
    dt = (b["ts_ms"] - a["ts_ms"]) / 1000
    tot = lambda r: sum(r[k] for k in ("user", "nice", "system", "idle", "iowait", "irq", "softirq"))
    dtot = tot(b) - tot(a)
    busy = 100 * (1 - (b["idle"] - a["idle"] + b["iowait"] - a["iowait"]) / dtot) if dtot else 0
    user = 100 * (b["user"] + b["nice"] - a["user"] - a["nice"]) / dtot if dtot else 0
    sys_ = 100 * (b["system"] + b["irq"] + b["softirq"] - a["system"] - a["irq"] - a["softirq"]) / dtot if dtot else 0
    mem = max(r["mem_total_kb"] - r["mem_avail_kb"] for r in seg) / 1024
    rss = max(r["rpc_rss_kb"] + r["bench_rss_kb"] for r in seg) / 1024
    rx = b["rx_bytes"] - a["rx_bytes"]; tx = b["tx_bytes"] - a["tx_bytes"]
    rxp = b["rx_packets"] - a["rx_packets"]; txp = b["tx_packets"] - a["tx_packets"]
    temp = max(r["temp_mc"] for r in seg) / 1000
    return dict(dt=dt, cpu_busy=busy, cpu_user=user, cpu_sys=sys_, mem_used_mb=mem, proc_rss_mb=rss,
                rx_MBps=rx / dt / 1e6, tx_MBps=tx / dt / 1e6, rx_pps=rxp / dt, tx_pps=txp / dt,
                avg_pkt_B=(rx + tx) / max(rxp + txp, 1), temp_max=temp, rx_bytes=rx, tx_bytes=tx, pkts=rxp + txp)

files = sorted(f for f in glob.glob(os.path.join(d, "*.csv")) if not os.path.basename(f).startswith("mon_summary"))
data = {os.path.basename(f)[:-4]: load(f) for f in files}
for k, rows in data.items():
    for r in rows:
        r["ts_ms"] -= OFF.get(k, 0)
data = {k: v for k, v in data.items() if len(v) >= 2}
w = windows()
if not w:
    t0 = max(v[0]["ts_ms"] for v in data.values()); t1 = min(v[-1]["ts_ms"] for v in data.values())
    w = {"run": (t0, t1)}

out = []
for ph, (t0, t1) in w.items():
    print(f"\n## {ph}（{(t1 - t0) / 1000:.1f} 秒）")
    print(f"{'设备':24s} {'CPU忙%':>7s} {'用户%':>6s} {'内核%':>6s} {'内存用MB':>8s} {'进程MB':>7s} {'收MB/s':>7s} {'发MB/s':>7s} {'收包/s':>7s} {'发包/s':>7s} {'包均B':>6s} {'温度':>5s}")
    for k, rows in data.items():
        s = stats(rows, t0, t1)
        if not s:
            continue
        extra = ""
        if ph == "decode" and N and R:   # decode 窗口里一共生成 N×R 个 token（不含预热）
            s["kB_per_token"] = (s["rx_bytes"] + s["tx_bytes"]) / (N * R) / 1000
            s["pkts_per_token"] = s["pkts"] / (N * R)
            extra = f"  每token {s['kB_per_token']:.0f} kB / {s['pkts_per_token']:.0f} 包"
        print(f"{k:24s} {s['cpu_busy']:7.1f} {s['cpu_user']:6.1f} {s['cpu_sys']:6.1f} {s['mem_used_mb']:8.0f} {s['proc_rss_mb']:7.0f} "
              f"{s['rx_MBps']:7.2f} {s['tx_MBps']:7.2f} {s['rx_pps']:7.0f} {s['tx_pps']:7.0f} {s['avg_pkt_B']:6.0f} {s['temp_max']:5.1f}{extra}")
        out.append(dict(phase=ph, node=k, **{x: round(y, 3) for x, y in s.items()}))
if out:
    with open(os.path.join(d, "mon_summary.csv"), "w", newline="") as fh:
        keys = list(dict.fromkeys(k for o in out for k in o))
        wr = csv.DictWriter(fh, fieldnames=keys); wr.writeheader(); wr.writerows(out)
    print(f"\n明细：{os.path.join(d, 'mon_summary.csv')}")
