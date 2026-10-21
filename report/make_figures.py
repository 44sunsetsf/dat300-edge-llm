#!/usr/bin/env python3
"""Generate all figures of the final report from the measurements of 2026-10-14.

Usage (on the laptop):  python3 report/make_figures.py [output_dir]   (default: report/figures)
Numbers come from the RESULT / BATCHED_DONE lines in logs/*.log (test id in the file name) and
from the GGML_RPC_TRACE timing logs in logs/trace/. Each data block below names its source.
"""
import csv, glob, os, statistics as st, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "figures")
os.makedirs(OUT, exist_ok=True)

plt.rcParams.update({
    "font.size": 10, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.3, "legend.frameon": False,
    "savefig.bbox": "tight", "savefig.dpi": 200,
})
C = {"single": "#7f7f7f", "dllama": "#9467bd", "stock": "#d62728", "opt": "#ff7f0e",
     "untied": "#2ca02c", "pp": "#1f77b4", "cat": "#8c564b"}

def save(fig, name):
    fig.savefig(os.path.join(OUT, name + ".pdf"))
    fig.savefig(os.path.join(OUT, name + ".png"))
    plt.close(fig)
    print("wrote", name)

# ---------------------------------------------------------------- 1. scaling (decode / prefill), 1-8 nodes
# 2026-10-14 (4 Pis): single A07, PP A10/A09, TP stock A06/A04, TP direct A05/A03, TP untied T02/U1, 4 thr T03
# 2026-10-21 (8 devices = 7 Pis + RK3588): TP untied S04 (busy-spin on) / F1 (GGML_RPC_NO_SPIN), stock T01, tied T02, PP P03
# Distributed Llama: Table 1 of the mid-term report (Pred. tok/s)
fig, ax = plt.subplots(figsize=(6.6, 4.0))
ax.plot([1, 2, 4], [1.97, 3.55, 5.81], color=C["dllama"], marker="D", ls=":", label="Distributed Llama (baseline)", lw=1.8)
ax.plot([1, 2, 4, 8], [1.84, 2.86, 1.03, 0.41], color=C["stock"], marker="x", ls="--", label="llama.cpp TP, stock", lw=1.8)
ax.plot([1, 2, 4, 8], [1.84, 3.00, 2.99, 1.42], color=C["opt"], marker="s", label="TP, direct allreduce (tied model)", lw=1.8)
ax.plot([1, 2, 4, 8], [1.84, 3.45, 4.85, 1.62], color=C["untied"], marker="^", ls="-.", alpha=0.6, label="TP, direct allreduce + untied (head busy-spin)", lw=1.5)
ax.plot([1, 2, 4, 8], [1.84, 3.46, 5.02, 6.34], color=C["untied"], marker="^", label="TP, direct allreduce + untied + no-spin", lw=2.2)
ax.plot([1, 2, 4, 8], [1.84, 1.88, 1.84, 2.00], color=C["pp"], marker="v", label="llama.cpp PP", lw=1.8)
ax.plot([1, 2, 4, 8], [1.84, 3.68, 7.36, 14.72], color="k", lw=0.8, ls=(0, (1, 3)), label="Ideal linear")
ax.axvspan(6, 9, color="#f2e8d5", alpha=0.5, lw=0); ax.text(7.2, 7.75, "8 = 7 Pis + RK3588", ha="center", fontsize=7.5, color="#7a5c2e")
ax.set_xscale("log", base=2); ax.set_xticks([1, 2, 4, 8]); ax.set_xticklabels(["1", "2", "4", "8"]); ax.set_xlim(0.85, 9)
ax.set_xlabel("Number of nodes"); ax.set_ylabel("Decode throughput (tokens/s)"); ax.set_ylim(0, 8.2); ax.legend(fontsize=7.5, loc="upper left")
save(fig, "decode_scaling")

fig, ax = plt.subplots(figsize=(6.6, 3.6))
ax.plot([1, 2, 4, 8], [4.14, 5.93, 5.77, 3.15], color=C["stock"], marker="x", ls="--", label="llama.cpp TP, stock", lw=1.8)
ax.plot([1, 2, 4, 8], [4.14, 5.94, 9.68, 12.34], color=C["opt"], marker="s", label="TP, direct allreduce (tied model)", lw=1.8)
ax.plot([1, 2, 4, 8], [4.14, 5.98, 12.57, 16.24], color=C["untied"], marker="^", label="TP, direct allreduce + untied + no-spin", lw=2.2)
ax.plot([1, 2, 4, 8], [4.14, 4.12, 4.01, 4.06], color=C["pp"], marker="v", label="llama.cpp PP", lw=1.8)
ax.axvspan(6, 9, color="#f2e8d5", alpha=0.5, lw=0)
ax.set_xscale("log", base=2); ax.set_xticks([1, 2, 4, 8]); ax.set_xticklabels(["1", "2", "4", "8"]); ax.set_xlim(0.85, 9)
ax.set_xlabel("Number of nodes"); ax.set_ylabel("Prefill throughput (tokens/s)"); ax.set_ylim(0, 18); ax.legend(fontsize=7.5, loc="upper left")
save(fig, "prefill_scaling")

# ---------------------------------------------------------------- 2. ablation at 4 nodes
# A04, T01, A03, B06 (fast model), B02 (ag), U1, T03
abl = [("Stock\n(tied)", 1.03, C["stock"]), ("Stock\n+ untied", 1.09, C["stock"]),
       ("Direct\nallreduce", 2.99, C["opt"]), ("+ Q4_0\noutput", 3.25, C["opt"]),
       ("+ untied\n+ ag", 4.81, C["untied"]), ("+ untied", 4.85, C["untied"]), ("+ untied\n+ 4 threads", 5.04, C["untied"])]
fig, ax = plt.subplots(figsize=(6.4, 3.2))
bars = ax.bar(range(len(abl)), [a[1] for a in abl], color=[a[2] for a in abl], width=0.65)
for b, a in zip(bars, abl):
    ax.text(b.get_x() + b.get_width() / 2, a[1] + 0.08, f"{a[1]:.2f}", ha="center", fontsize=8.5)
ax.axhline(1.84, color=C["single"], ls="--", lw=1); ax.text(0.5, 1.95, "single node 1.84", ha="center", fontsize=8, color=C["single"])
ax.set_xticks(range(len(abl))); ax.set_xticklabels([a[0] for a in abl], fontsize=8)
ax.set_ylabel("Decode throughput (tokens/s)"); ax.set_ylim(0, 5.8); ax.grid(axis="x")
save(fig, "ablation_tp4")

# ---------------------------------------------------------------- 3. per-token breakdown from traces
def trace_breakdown(d):
    """Per node: (layers_ms, output_ms, sync_ms, idle_ms, other_ms) for decode tokens."""
    res = {}
    for f in sorted(glob.glob(os.path.join(REPO, "logs/trace", d, "*_10.77.*.csv"))):
        rows = list(csv.DictReader(open(f)))
        toks, cur, seen = [], None, False
        for r in rows:
            c = r["cmd"]
            if seen and c == "SET_TENSOR" and cur is not None and cur["g"]:
                toks.append(cur); cur = None; seen = False
            if cur is None:
                cur = {"g": [], "ar": 0, "ar_bytes": None, "idle": 0, "x": 0}
            cur["idle"] += int(r["idle_us"])
            if c.startswith("GRAPH"):
                cur["g"].append(int(r["dur_us"])); seen = True
            elif c == "COMM_ALLREDUCE":
                cur["ar"] += int(r["dur_us"])
                b = int(r["detail"].split("bytes=")[1].split()[0])
                cur["ar_bytes"] = b if cur["ar_bytes"] is None else min(cur["ar_bytes"], b)
            else:
                cur["x"] += int(r["dur_us"])
        dec = [t for t in toks if len(t["g"]) == 57 and t["ar_bytes"] == 12288]
        walls = [sum(t["g"]) + t["ar"] + t["idle"] + t["x"] for t in dec]
        med = st.median(walls)
        dec = [t for t, w in zip(dec, walls) if w < 1.5 * med]
        name = os.path.basename(f)[:-4]
        res[name] = tuple(st.mean(v) / 1000 for v in zip(*[(sum(t["g"][:56]), t["g"][56], t["ar"], t["idle"], t["x"]) for t in dec]))
    return res

NODES = [("rex_10.77.0.4", "rex (head)"), ("finn_10.77.0.2", "finn"), ("pi_10.77.0.3", "han"), ("pi_10.77.0.5", "luthen (Pi 4B)")]
tied = trace_breakdown("tp_4n_opt_B10_tp4_trace_1014_160744")
unt = trace_breakdown("tp_4n_opt_U1_untied_1014_163229")
for nm, d in (("tied", tied), ("untied", unt)):
    print(nm, {k: [round(x, 1) for x in v] for k, v in d.items()})

fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.3), sharey=True)
parts = [("Transformer layers", "#4c72b0"), ("Output layer (lm_head)", "#dd8452"),
         ("Allreduce (incl. waiting)", "#c44e52"), ("Idle (waiting for head)", "#bbbbbb")]
for ax, (title, d) in zip(axes, (("Original model (tied output)\n4 nodes: 2.99 tok/s", tied), ("Untied output layer\n4 nodes: 4.85 tok/s", unt))):
    bottom = [0] * len(NODES)
    for j, (pn, col) in enumerate(parts):
        vals = [d[n][j] for n, _ in NODES]
        ax.bar(range(len(NODES)), vals, bottom=bottom, color=col, width=0.6, label=pn)
        bottom = [b + v for b, v in zip(bottom, vals)]
    for i, b in enumerate(bottom):
        ax.text(i, b + 5, f"{b:.0f}", ha="center", fontsize=8)
    ax.set_xticks(range(len(NODES))); ax.set_xticklabels([l for _, l in NODES], fontsize=8, rotation=15)
    ax.set_title(title, fontsize=9.5); ax.grid(axis="x")
axes[0].set_ylabel("Time per decode token (ms)")
axes[1].legend(fontsize=7.5, loc="upper right")
save(fig, "trace_breakdown_tp4")

# ---------------------------------------------------------------- 4. head traffic per token (A04 vs A03, A06 vs A05)
fig, ax = plt.subplots(figsize=(5.2, 3.0))
lab = ["2 nodes", "4 nodes"]
stock_tx = [776, 49862]; opt_tx = [773, 1627]
x = range(2)
ax.bar([i - 0.18 for i in x], stock_tx, 0.35, color=C["stock"], label="stock (relay through head)")
ax.bar([i + 0.18 for i in x], opt_tx, 0.35, color=C["opt"], label="direct allreduce (ours)")
for i in x:
    ax.text(i - 0.18, stock_tx[i] * 1.15, f"{stock_tx[i]/1000:.1f} MB", ha="center", fontsize=8)
    ax.text(i + 0.18, opt_tx[i] * 1.15, f"{opt_tx[i]/1000:.1f} MB", ha="center", fontsize=8)
ax.set_yscale("log"); ax.set_ylim(300, 2e5); ax.set_xticks(list(x)); ax.set_xticklabels(lab)
ax.set_ylabel("Sent by head per token (kB)"); ax.legend(fontsize=8, loc="upper left"); ax.grid(axis="x")
save(fig, "head_traffic")

# ---------------------------------------------------------------- 5. PP: pipelined prefill (P04, P05, P06) and batching (P11-P14)
fig, axes = plt.subplots(1, 2, figsize=(7.6, 3.2), gridspec_kw={"width_ratios": [1, 1.35]})
ax = axes[0]
cfg = [("Single\n-ub 32", 4.13, C["single"]), ("PP 4 nodes\n-ub 128\n(1 chunk)", 4.16, C["pp"]), ("PP 4 nodes\n-ub 32\n(4 chunks)", 4.68, "#17becf")]
bars = ax.bar(range(3), [c[1] for c in cfg], color=[c[2] for c in cfg], width=0.6)
for b, c in zip(bars, cfg):
    ax.text(b.get_x() + b.get_width() / 2, c[1] + 0.1, f"{c[1]:.2f}", ha="center", fontsize=8.5)
ax.axhline(4.16 * 16 / 7, color="k", ls=":", lw=1); ax.text(2.4, 4.16 * 16 / 7 + 0.15, "ideal 4-stage pipeline", ha="right", fontsize=7.5)
ax.set_xticks(range(3)); ax.set_xticklabels([c[0] for c in cfg], fontsize=7.5); ax.set_ylim(0, 11)
ax.set_ylabel("Prefill throughput (tokens/s)"); ax.set_title("(a) Pipelined prefill, 128-token prompt", fontsize=9); ax.grid(axis="x")
ax = axes[1]
B = [1, 4, 8]
ax.plot(B, [1.85, 3.40, 3.46], marker="o", color=C["single"], label="Single node")
ax.plot(B, [1.83, 3.17, 3.24], marker="v", color=C["pp"], label="PP, 4 nodes")
ax.plot([8], [4.18], marker="*", ms=12, ls="none", color="#17becf", label="PP, 4 nodes, -ub 2 (pipelined decode)")
ax.plot(B, [4.26, 6.46, 7.83], marker="^", color=C["untied"], label="TP, 4 nodes (untied, 4 threads)")
ax.set_xticks(B); ax.set_xlabel("Concurrent requests"); ax.set_ylabel("Aggregate decode throughput (tokens/s)")
ax.set_ylim(0, 11.5); ax.legend(fontsize=7.5, loc="upper left"); ax.set_title("(b) Serving several requests at once", fontsize=9)
save(fig, "pp_pipeline_batching")

# ---------------------------------------------------------------- 6. heterogeneous: cat (RK3588)
fig, axes = plt.subplots(1, 2, figsize=(8.6, 3.6), gridspec_kw={"width_ratios": [1, 1.9]})
ax = axes[0]
cat = [("A72 build\n4 big cores", 5.84, 7.48), ("A76 build\n8 cores", 10.12, 47.44), ("A76 build\n4 big cores", 12.28, 48.75)]
x = range(3)
ax.bar([i - 0.18 for i in x], [c[1] for c in cat], 0.35, color=C["cat"], label="decode")
ax.bar([i + 0.18 for i in x], [c[2] for c in cat], 0.35, color="#e7a77a", label="prefill (32 tok)")
for i, c in enumerate(cat):
    ax.text(i - 0.18, c[1] + 0.8, f"{c[1]:.1f}", ha="center", fontsize=7.5); ax.text(i + 0.18, c[2] + 0.8, f"{c[2]:.1f}", ha="center", fontsize=7.5)
ax.set_xticks(list(x)); ax.set_xticklabels([c[0] for c in cat], fontsize=7.5); ax.set_ylabel("tokens/s")
ax.set_title("(a) LubanCat-5 single board", fontsize=9); ax.legend(fontsize=7.5, loc="upper left"); ax.set_ylim(0, 58); ax.grid(axis="x")
ax = axes[1]
het = [("TP rex+cat\neven", 3.24), ("TP rex+cat\n-ts 1/4", 7.00), ("PP rex+cat\neven", 3.07), ("PP rex+cat\n-ts 1/6", 5.52),
       ("TP cat + 3 Pi\neven", 4.57), ("4 Pi TP\n(reference)", 5.04), ("cat alone", 12.28)]
cols = [C["untied"], C["untied"], C["pp"], C["pp"], C["untied"], C["single"], C["cat"]]
bars = ax.bar(range(len(het)), [h[1] for h in het], color=cols, width=0.62)
for b, h in zip(bars, het):
    ax.text(b.get_x() + b.get_width() / 2, h[1] + 0.2, f"{h[1]:.2f}", ha="center", fontsize=7.5)
for i in (1, 3):
    bars[i].set_hatch("//"); bars[i].set_edgecolor("white")
ax.set_xticks(range(len(het))); ax.set_xticklabels([h[0] for h in het], fontsize=7, rotation=30, ha="right"); ax.set_ylabel("Decode throughput (tokens/s)")
ax.set_title("(b) Mixing the RK3588 board with Pis (hatched: weighted split)", fontsize=9); ax.set_ylim(0, 14); ax.grid(axis="x")
save(fig, "heterogeneous")

# ---------------------------------------------------------------- 7. performance model (Eq. model) vs measurement at 1-8 nodes
T1, TO = 1000 / 1.84, 83.0          # single-node ms/token; output layer (trace, 80-85 ms)
TL = T1 - TO
t_round, n_sync = 0.30, 56           # ms per allreduce round incl. waiting (fit at 4 nodes)
def host(N): return {1: 0, 2: 8, 4: 33, 8: 15}[N]   # idle time waiting for the head, from the traces (8 nodes: no-spin run F1)
def model(N, untied=True):
    import math
    out = TO / N if untied else TO
    return TL / N + out + (n_sync * t_round * math.log2(N) if N > 1 else 0) + host(N)
Ns = [1, 2, 4, 8]
fig, ax = plt.subplots(figsize=(5.8, 3.5))
ax.plot(Ns, [1000 / model(n, True) for n in Ns], color=C["untied"], ls="--", marker="^", mfc="none", label="model, untied (Eq. 7)")
ax.plot([1, 2, 4, 8], [1.84, 3.46, 5.02, 6.34], color=C["untied"], marker="^", ls="none", ms=8, label="measured, untied + no-spin")
ax.plot([8], [1.62], color=C["stock"], marker="X", ls="none", ms=9, label="measured, 8 nodes with busy-spin")
ax.set_xticks(Ns); ax.set_xlabel("Number of nodes"); ax.set_ylabel("Decode throughput (tokens/s)")
ax.set_ylim(0, 8); ax.legend(fontsize=8, loc="upper left")
save(fig, "perf_model")
print("model ms/token:", {n: round(model(n, True), 1) for n in Ns})

# ---------------------------------------------------------------- 8. topology of the lab cluster (8 devices)
fig, ax = plt.subplots(figsize=(7.0, 3.6)); ax.axis("off"); ax.set_xlim(-0.3, 11); ax.set_ylim(0, 6)
ax.add_patch(FancyBboxPatch((3.6, 2.6), 3.8, 0.8, boxstyle="round,pad=0.05", fc="#dbe9f6", ec="#1f77b4"))
ax.text(5.5, 3.0, "Netgear M4300-28G\nGigabit switch", ha="center", va="center", fontsize=8)
nodes = [(0.9, 5.2, "rex  .4\nPi 400, head"), (3.0, 5.4, "finn  .2\nPi 400"), (5.0, 5.5, "han  .3\nPi 400"),
         (7.0, 5.4, "cassian  .7\nPi 400"), (9.6, 5.2, "laptop  .100\n(control, ssh)"),
         (0.9, 0.8, "luthen  .5\nPi 4B"), (3.0, 0.6, "jarjar  .8\nPi 4B"), (5.0, 0.5, "crosshair  .9\nPi 4B"),
         (7.4, 0.6, "cat  .6\nLubanCat-5 (RK3588)")]
for x, y, t in nodes:
    ax.plot([x, 5.5], [y - 0.35 if y > 3 else y + 0.35, 3.4 if y > 3 else 2.6], color="#555", lw=1)
    ec = "#8c564b" if "cat" in t else ("#7f7f7f" if "laptop" in t else "#2ca02c")
    ax.add_patch(FancyBboxPatch((x - 0.95, y - 0.35), 1.9, 0.7, boxstyle="round,pad=0.04", fc="white", ec=ec))
    ax.text(x, y, t, ha="center", va="center", fontsize=7.2)
ax.text(10.9, 2.0, "1 Gbit/s Ethernet\nstar topology\nRTT 0.06-0.24 ms\nTCP 940 Mbit/s", ha="right", fontsize=7.2, color="#555")
save(fig, "topology")

# ---------------------------------------------------------------- 9. device performance (2026-10-21 measurements)
# membw (tools/membw.c, 128 MB arrays, best of 8): Pi 400 3.7-5.3 GB/s, Pi 4B 4.0-5.3 GB/s, RK3588 21-23 GB/s
dev = [("Raspberry Pi 400\n(4x A72 1.8 GHz)", 3.9, 5.27, 1.84), ("Raspberry Pi 4B\n(4x A72 1.8 GHz)", 4.1, 5.27, 1.84),
       ("LubanCat-5 RK3588\n(4x A76 2.3 GHz)", 22.1, 21.6, 12.28)]
fig, axes = plt.subplots(1, 2, figsize=(7.6, 3.1))
ax = axes[0]; x = range(3)
ax.bar([i - 0.18 for i in x], [d[1] for d in dev], 0.35, color="#4c72b0", label="4 threads (copy/triad avg.)")
ax.bar([i + 0.18 for i in x], [d[2] for d in dev], 0.35, color="#9ecae1", label="1 thread (copy)")
for i, d in enumerate(dev):
    ax.text(i - 0.18, d[1] + 0.4, f"{d[1]:.1f}", ha="center", fontsize=7.5); ax.text(i + 0.18, d[2] + 0.4, f"{d[2]:.1f}", ha="center", fontsize=7.5)
ax.set_xticks(list(x)); ax.set_xticklabels([d[0] for d in dev], fontsize=7); ax.set_ylabel("Memory bandwidth (GB/s)")
ax.set_title("(a) Measured memory bandwidth", fontsize=9); ax.legend(fontsize=7, loc="upper left"); ax.set_ylim(0, 27); ax.grid(axis="x")
ax = axes[1]
bw_used = [d[3] * 1.92 for d in dev]   # decode reads ~1.92 GB of weights per token
ax.bar(x, [d[3] for d in dev], 0.55, color=["#2ca02c", "#2ca02c", C["cat"]])
for i, d in enumerate(dev):
    ax.text(i, d[3] + 0.3, f"{d[3]:.2f} tok/s\n= {bw_used[i]:.1f} GB/s", ha="center", fontsize=7.2)
ax.set_xticks(list(x)); ax.set_xticklabels([d[0] for d in dev], fontsize=7); ax.set_ylabel("Single-device decode (tokens/s)")
ax.set_title("(b) Single-device decode and implied weight traffic", fontsize=9); ax.set_ylim(0, 16); ax.grid(axis="x")
save(fig, "device_performance")

# ---------------------------------------------------------------- 10. per-node resource utilization in decode (monitoring)
def mon(tag):
    d = glob.glob(os.path.join(REPO, "logs/mon", f"*_{tag}_1021_*"))
    rows = [r for r in csv.DictReader(open(sorted(d)[-1] + "/mon_summary.csv")) if r["phase"] == "decode"]
    return {r["node"]: r for r in rows}
ORDER8 = ["rex_10.77.0.4", "finn_10.77.0.2", "pi_10.77.0.3", "cassian_10.77.0.7", "pi_10.77.0.5", "jarjar_10.77.0.8", "crosshair_10.77.0.9", "cat_10.77.0.6"]
NAMES8 = ["rex\n(head)", "finn", "han", "cassian", "luthen", "jarjar", "cross-\nhair", "cat"]
runs = [("TP 2", "S02_tp2"), ("TP 4", "F2_tp4_nospin"), ("TP 8, busy-spin", "S04_tp8"), ("TP 8, no-spin", "F1_tp8_nospin"), ("PP 8", "P03_pp8")]
fig, axes = plt.subplots(1, 2, figsize=(8.4, 3.3), gridspec_kw={"width_ratios": [1.6, 1]})
ax = axes[0]; W = 0.16
cols = ["#9ecae1", "#6baed6", C["stock"], C["untied"], C["pp"]]
for j, (lab, tag) in enumerate(runs):
    m = mon(tag); vals = [float(m[n]["cpu_busy"]) if n in m else 0 for n in ORDER8]
    ax.bar([i + (j - 2) * W for i in range(8)], vals, W, color=cols[j], label=lab)
ax.set_xticks(range(8)); ax.set_xticklabels(NAMES8, fontsize=7); ax.set_ylabel("CPU busy in decode (%)"); ax.set_ylim(0, 105)
ax.set_title("(a) CPU utilization per device", fontsize=9); ax.legend(fontsize=7, ncol=3, loc="upper right"); ax.grid(axis="x")
ax = axes[1]
lab = ["TP 2", "TP 4", "TP 8\nspin", "TP 8\nno-spin", "PP 8"]
kb = []; pk = []; mbps = []
for _, tag in runs:
    m = mon(tag); w = [n for n in ORDER8[1:7] if n in m] or [n for n in m if not n.startswith("rex")]
    kb.append(st.mean(float(m[n]["kB_per_token"]) for n in w)); pk.append(st.mean(float(m[n]["pkts_per_token"]) for n in w))
    mbps.append(st.mean(float(m[n]["rx_MBps"]) + float(m[n]["tx_MBps"]) for n in w))
ax.bar(range(5), [k / 1000 for k in kb], 0.55, color=cols)
for i in range(5):
    ax.text(i, kb[i] / 1000 + 0.08, f"{kb[i]/1000:.1f} MB\n{pk[i]:.0f} pkts\n{mbps[i]*8:.0f} Mbit/s", ha="center", fontsize=6.5)
ax.set_xticks(range(5)); ax.set_xticklabels(lab, fontsize=7); ax.set_ylabel("Worker traffic per token (MB, rx+tx)"); ax.set_ylim(0, 5.8)
ax.set_title("(b) Network per worker", fontsize=9); ax.grid(axis="x")
save(fig, "resources_decode")

# ---------------------------------------------------------------- 11. CPU time series during the 8-node runs (busy-spin vs no-spin)
def series(tag, node):
    d = sorted(glob.glob(os.path.join(REPO, "logs/mon", f"*_{tag}_1021_*")))[-1]
    off = {}   # clock offsets (only recorded since the runs after 16:15; the earlier runs used freshly synced clocks)
    if os.path.exists(d + "/offsets.txt"):
        for line in open(d + "/offsets.txt"):
            k, v = line.split()
            if k != "__head__": off[k] = int(v)
    rows = [r for r in csv.DictReader(open(f"{d}/{node}.csv"))]
    t, c = [], []
    for a, b in zip(rows, rows[1:]):
        try:
            tot = lambda r: sum(int(r[k]) for k in ("user", "nice", "system", "idle", "iowait", "irq", "softirq"))
            dt = tot(b) - tot(a)
            t.append((int(b["ts_ms"]) - off.get(node, 0)) / 1000); c.append(100 * (1 - (int(b["idle"]) + int(b["iowait"]) - int(a["idle"]) - int(a["iowait"])) / dt) if dt else 0)
        except (ValueError, KeyError):
            pass
    ph = [l.split(" ", 1) for l in open(d + "/phases.txt") if "generation run 1/" in l]
    hoff = off.get("rex_10.77.0.4", 0)
    g0 = (int(ph[0][0]) - hoff) / 1000 if ph else t[0]
    return [x - g0 for x in t], c
fig, axes = plt.subplots(1, 2, figsize=(8.2, 2.9), sharey=True)
for ax, (title, tag) in zip(axes, (("8 nodes, busy-spin (1.62 tok/s)", "S04_tp8"), ("8 nodes, no-spin (6.34 tok/s)", "F1_tp8_nospin"))):
    for node, lab, col in (("rex_10.77.0.4", "rex (head)", C["stock"]), ("finn_10.77.0.2", "finn (Pi 400)", "#4c72b0"),
                           ("jarjar_10.77.0.8", "jarjar (Pi 4B)", "#6baed6"), ("cat_10.77.0.6", "cat (RK3588)", C["cat"])):
        t, c = series(tag, node)
        ax.plot(t, c, label=lab, color=col, lw=1.2)
    ax.axvline(0, color="k", lw=0.8, ls=":"); ax.text(0.5, 101, "decode starts", fontsize=7)
    ax.set_xlim(-20, 40); ax.set_ylim(0, 108); ax.set_xlabel("Time from first measured decode run (s)", fontsize=8.5); ax.set_title(title, fontsize=9)
axes[0].set_ylabel("CPU busy (%)"); axes[1].legend(fontsize=7, loc="lower right")
save(fig, "cpu_timeline_tp8")

# ---------------------------------------------------------------- 12. trace breakdown at 8 nodes (busy-spin vs no-spin)
spin8 = trace_breakdown("tp_8n_opt_T04_tp8_trace_1021_163217")
nospin8 = trace_breakdown("tp_8n_opt_F1_tp8_nospin_1021_165251")
fig, axes = plt.subplots(1, 2, figsize=(8.2, 3.2), sharey=True)
for ax, (title, d) in zip(axes, (("Busy-spin (default): 1.59 tok/s", spin8), ("GGML_RPC_NO_SPIN=1: 6.34 tok/s", nospin8))):
    bottom = [0] * 8
    for j, (pn, col) in enumerate(parts):
        vals = [d[n][j] if n in d else 0 for n in ORDER8]
        ax.bar(range(8), vals, bottom=bottom, color=col, width=0.62, label=pn)
        bottom = [b + v for b, v in zip(bottom, vals)]
    for i, b in enumerate(bottom):
        ax.text(i, b + 8, f"{b:.0f}", ha="center", fontsize=6.5)
    ax.set_xticks(range(8)); ax.set_xticklabels(NAMES8, fontsize=6.8); ax.set_title(title, fontsize=9); ax.grid(axis="x")
axes[0].set_ylabel("Time per decode token (ms)"); axes[1].legend(fontsize=7, loc="upper right")
save(fig, "trace_breakdown_tp8")
for nm, d in (("spin8", spin8), ("nospin8", nospin8)):
    print(nm, {k: [round(x, 1) for x in v] for k, v in d.items()})

# ---------------------------------------------------------------- 13. head bottleneck experiments
hb = [("4 nodes\nhead rex", 4.72, "#9ecae1"), ("4 nodes\nhead cat", 5.31, "#9ecae1"), ("4 nodes\nno-spin", 5.02, C["untied"]),
      ("8 nodes\nhead rex", 1.62, "#fcae91"), ("8 nodes\nrex rpc 2 thr", 1.63, "#fcae91"), ("8 nodes\nhead cat", 0.72, "#fcae91"),
      ("8 nodes\nno-spin", 6.34, C["untied"])]
fig, ax = plt.subplots(figsize=(6.8, 3.0))
bars = ax.bar(range(len(hb)), [h[1] for h in hb], color=[h[2] for h in hb], width=0.62)
for b_, h in zip(bars, hb):
    ax.text(b_.get_x() + b_.get_width() / 2, h[1] + 0.1, f"{h[1]:.2f}", ha="center", fontsize=8)
ax.axvline(2.5, color="#999", lw=0.8)
ax.set_xticks(range(len(hb))); ax.set_xticklabels([h[0] for h in hb], fontsize=7.5); ax.set_ylabel("Decode throughput (tokens/s)")
ax.set_ylim(0, 7.3); ax.grid(axis="x")
save(fig, "head_bottleneck")
