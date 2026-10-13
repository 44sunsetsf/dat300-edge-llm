#!/usr/bin/env python3
"""汇总 logs/ 里所有 run_bench.sh 日志的 RESULT 行，输出一张 Markdown 表（同时写到 logs/summary.md）。

用法：python3 scripts/summarize.py [只看文件名包含这个字符串的日志，例如 A0]
decode 的"相对单机"用同一个 build 的 single 结果作基准（没有的话用 1.85 tok/s）。
"""
import glob, os, re, sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
filt = sys.argv[1] if len(sys.argv) > 1 else ""
rows = []
for path in sorted(glob.glob(os.path.join(repo, "logs", "*.log"))):
    name = os.path.basename(path)
    if filt not in name:
        continue
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("RESULT "):
            kv = dict(p.split("=", 1) for p in line.split()[1:] if "=" in p)
            kv["log"] = name
            rows.append(kv)

def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

single = {r["build"]: num(r.get("decode")) for r in rows if r.get("mode") == "single" and num(r.get("decode"))}
order = {"single": 0, "tp": 1, "pp": 2}
rows.sort(key=lambda r: (order.get(r.get("mode"), 9), -int(r.get("nn", 0)), r.get("netem_ms", ""), r.get("build", ""), r.get("rpc_t", "")))

out = ["| 模式 | 台数 | 版本 | rpc线程(HEAD) | 额外设置 | 加延迟 | prefill tok/s | decode tok/s | ms/token | 相对单机 | HEAD 流量 收/发 kB | CPU% | 日志 |",
       "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
for r in rows:
    d = num(r.get("decode"))
    base = single.get(r.get("build")) or 1.85
    extra = " ".join(x for x in (r.get("env", ""), r.get("extra", "")) if x).replace(",", " ")
    out.append("| {} | {} | {} | {}({}) | {} | {} ms | {} | {} | {} | {} | {} | {} | {} |".format(
        r.get("mode"), r.get("nn"), "改进版" if r.get("build") == "opt" else "原版",
        r.get("rpc_t"), r.get("rpc_t_head"), extra or "-", r.get("netem_ms", "0"),
        r.get("prefill"), r.get("decode"),
        f"{1000 / d:.0f}" if d else "-", f"{d / base:.2f}x" if d else "-",
        r.get("head_kb", "-"), r.get("cpu", "-"), r["log"]))
text = "\n".join(out)
print(text)
with open(os.path.join(repo, "logs", "summary.md"), "w", encoding="utf-8") as f:
    f.write("# 测量汇总（scripts/summarize.py 自动生成）\n\n" + text + "\n")
