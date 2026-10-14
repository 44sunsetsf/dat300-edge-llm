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

# ---------------------------------------------------------------- 1. scaling (decode / prefill)
# single: A07; PP: A10/A09; TP stock: A06/A04; TP opt tied: A05/A03; TP opt untied: T02/U1 (3 thr), T03 (4 thr)
# Distributed Llama: Table 1 of the mid-term report (Pred. tok/s)
dec = {
    "Single node (llama.cpp)": ([1], [1.84], C["single"], "o", "-"),
    "Distributed Llama (baseline)": ([1, 2, 4], [1.97, 3.55, 5.81], C["dllama"], "D", ":"),
    "llama.cpp TP, stock": ([1, 2, 4], [1.84, 2.86, 1.03], C["stock"], "x", "--"),
    "llama.cpp TP, direct allreduce": ([1, 2, 4], [1.84, 3.00, 2.99], C["opt"], "s", "-"),
    "llama.cpp TP, direct allreduce + untied": ([1, 2, 4], [1.84, 3.45, 4.85], C["untied"], "^", "-"),
    "llama.cpp PP": ([1, 2, 4], [1.84, 1.88, 1.84], C["pp"], "v", "-"),
}
fig, ax = plt.subplots(figsize=(6.2, 3.8))
for k, (x, y, c, m, ls) in dec.items():
    if len(x) > 1:
        ax.plot(x, y, color=c, marker=m, ls=ls, label=k, lw=1.8)
ax.plot([4], [5.04], marker="*", ms=12, color=C["untied"], ls="none", label="  + 4 threads per rpc-server")
ax.plot([1, 2, 4], [1.84, 3.68, 7.36], color="k", lw=0.8, ls=(0, (1, 3)), label="Ideal linear")
ax.set_xticks([1, 2, 4]); ax.set_xlabel("Number of Raspberry Pi nodes"); ax.set_ylabel("Decode throughput (tokens/s)")
ax.set_ylim(0, 7.8); ax.legend(fontsize=8, loc="upper left")
save(fig, "decode_scaling")

pre = {
    "llama.cpp TP, stock": ([1, 2, 4], [4.14, 5.93, 5.77], C["stock"], "x", "--"),
    "llama.cpp TP, direct allreduce": ([1, 2, 4], [4.14, 5.94, 9.68], C["opt"], "s", "-"),
    "llama.cpp TP, direct allreduce + untied": ([1, 2, 4], [4.14, 5.98, 10.07], C["untied"], "^", "-"),
    "llama.cpp PP": ([1, 2, 4], [4.14, 4.12, 4.01], C["pp"], "v", "-"),
}
fig, ax = plt.subplots(figsize=(6.2, 3.4))
for k, (x, y, c, m, ls) in pre.items():
    ax.plot(x, y, color=c, marker=m, ls=ls, label=k, lw=1.8)
ax.plot([4], [12.57], marker="*", ms=12, color=C["untied"], ls="none", label="  + 4 threads per rpc-server")
ax.set_xticks([1, 2, 4]); ax.set_xlabel("Number of Raspberry Pi nodes"); ax.set_ylabel("Prefill throughput (tokens/s)")
ax.set_ylim(0, 14); ax.legend(fontsize=8, loc="upper left")
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

# ---------------------------------------------------------------- 7. performance model (Eq. 7) vs measurement, projection to 8 nodes
T1, TO = 1000 / 1.84, 83.0          # single-node ms/token; output layer (trace, 80-85 ms)
TL = T1 - TO
t_round, n_sync = 0.30, 56           # ms per allreduce round incl. jitter/waiting (fit at N=4 untied: ~34 ms / (56*2))
def host(N): return {1: 0, 2: 8, 4: 33, 8: 45}[N]   # idle time waiting for the head (trace); N=8 extrapolated
def model(N, untied=True):
    import math
    out = TO / N if untied else TO
    return TL / N + out + (n_sync * t_round * math.log2(N) if N > 1 else 0) + host(N)
Ns = [1, 2, 4, 8]
fig, ax = plt.subplots(figsize=(5.6, 3.4))
ax.plot(Ns, [1000 / model(n, True) for n in Ns], color=C["untied"], ls="--", marker="^", mfc="none", label="model, untied (Eq. 7)")
ax.plot(Ns, [1000 / model(n, False) for n in Ns], color=C["opt"], ls="--", marker="s", mfc="none", label="model, tied output")
ax.plot([1, 2, 4], [1.84, 3.45, 4.85], color=C["untied"], marker="^", ls="none", ms=8, label="measured, untied")
ax.plot([1, 2, 4], [1.84, 3.00, 2.99], color=C["opt"], marker="s", ls="none", ms=8, label="measured, tied")
ax.set_xticks(Ns); ax.set_xlabel("Number of Raspberry Pi nodes"); ax.set_ylabel("Decode throughput (tokens/s)")
ax.set_ylim(0, 8); ax.legend(fontsize=8, loc="upper left")
ax.annotate("projection", xy=(8, 1000 / model(8)), xytext=(6.3, 7.2), fontsize=8, arrowprops=dict(arrowstyle="->", lw=0.8))
save(fig, "perf_model")
print("model ms/token:", {n: (round(model(n, True), 1), round(model(n, False), 1)) for n in Ns})

# ---------------------------------------------------------------- 8. topology of the lab cluster
fig, ax = plt.subplots(figsize=(6.4, 3.4)); ax.axis("off"); ax.set_xlim(0, 10); ax.set_ylim(0, 6)
ax.add_patch(FancyBboxPatch((3.1, 2.6), 3.8, 0.8, boxstyle="round,pad=0.05", fc="#dbe9f6", ec="#1f77b4"))
ax.text(5, 3.0, "Netgear M4300-28G\n10.77.0.1 (DHCP, MAC bindings)", ha="center", va="center", fontsize=8)
nodes = [(1.1, 5.2, "rex  .4\nPi 400, head"), (3.7, 5.4, "finn  .2\nPi 400"), (6.3, 5.4, "han  .3\nPi 400"),
         (8.9, 5.2, "luthen  .5\nPi 4B"), (1.6, 0.7, "laptop  .100\n(controls via ssh)"), (5.0, 0.5, "cat  .6\nLubanCat-5 (RK3588)"),
         (8.3, 0.7, "more Pis\n.101-.199 (DHCP)")]
for x, y, t in nodes:
    ax.plot([x, 5], [y - 0.35 if y > 3 else y + 0.35, 3.4 if y > 3 else 2.6], color="#555", lw=1)
    ec = "#2ca02c" if "Pi" in t and "laptop" not in t else ("#8c564b" if "cat" in t else "#7f7f7f")
    ax.add_patch(FancyBboxPatch((x - 1.05, y - 0.35), 2.1, 0.7, boxstyle="round,pad=0.04", fc="white", ec=ec))
    ax.text(x, y, t, ha="center", va="center", fontsize=7.5)
ax.text(9.9, 2.0, "1 Gbit/s Ethernet\nstar topology\nRTT 0.05-0.15 ms", ha="right", fontsize=7.5, color="#555")
save(fig, "topology")
