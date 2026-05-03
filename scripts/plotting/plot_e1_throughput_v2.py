#!/usr/bin/env python3
"""Fig 1: E1 throughput vs n. Three protocols, eno1 setup.
   d=100, 1M total gates, n in {3,4,5,6}.
"""
import os, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

OUT = os.path.join(HERE, "..", "..", "graphs", "e1_throughput_vs_n.png")
BASE = os.path.join(HERE, "..", "..", "results", "e1_n_sweep_eno1")

plt.rcParams.update({
    "font.size": 13, "axes.titlesize": 14, "axes.labelsize": 13,
    "xtick.labelsize": 12, "ytick.labelsize": 12, "legend.fontsize": 12,
    "axes.linewidth": 1.2, "lines.linewidth": 2.4, "lines.markersize": 9,
})

PROTOS = [
    ("sync",  "Asterisk (sync)",            "#1f77b4", "o"),
    ("qsync", "QSync-MPC (quasi-sync)",      "#2ca02c", "^"),
    ("async", "Castor (async)",              "#d62728", "s"),
]

def load(path):
    out = {}  # n -> (max_t_ms, throughput_mul_s)
    if not os.path.isfile(path): return out
    with open(path) as f:
        for r in csv.DictReader(f, delimiter='\t'):
            if r.get("status") != "ok": continue
            out[int(r["n"])] = (float(r["max_t_ms"]), float(r["throughput_mul_s"]))
    return out

# Castor DM: add projected offline phase. Per the Castor paper (Table 1,
# DM @ 10^6 mul, d=100), the OLE-dominated offline time scales ~1000 s × n.
# Online time we measured. Projected combined throughput = 1M / (online + offline).
TOTAL_GATES = 1_000_000
def offline_castor_dm_seconds(n):
    return 1000.0 * n   # paper Table 1 fit, OT-bound preproc

fig, ax = plt.subplots(figsize=(8, 6.5))
for pkey, label, color, marker in PROTOS:
    data = load(f"{BASE}/{pkey}/summary.tsv")
    if not data: continue
    ns = sorted(data.keys())
    if pkey == "async":
        ys = []
        for n in ns:
            online_s = data[n][0] / 1000.0
            total_s = online_s + offline_castor_dm_seconds(n)
            ys.append(TOTAL_GATES / total_s / 1000.0)  # k mul/s
    else:
        ys = [data[n][1]/1000 for n in ns]
    ax.plot(ns, ys, marker=marker, color=color, label=label)
    for n, y in zip(ns, ys):
        if y >= 1:
            tag = f"{y:.0f}k"
        else:
            tag = f"{y*1000:.0f}"
        ax.annotate(tag, (n, y), textcoords="offset points",
                    xytext=(0, 9), ha="center", fontsize=11, color=color)

ax.set_xlabel("Number of parties")
ax.set_ylabel("Throughput (k mul/s)")
ax.set_xticks([3, 4, 5, 6])
# Add headroom above the highest point so annotations like "51k" don't clip.
ymax = ax.get_ylim()[1]
ax.set_ylim(0, ymax * 1.12)
ax.grid(True, alpha=0.3)
ax.legend(loc="best", framealpha=0.9)
fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
