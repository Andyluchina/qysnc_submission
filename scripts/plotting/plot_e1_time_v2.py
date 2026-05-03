#!/usr/bin/env python3
"""Fig 2: E1 end-to-end time vs n. Three protocols, eno1 setup.
   d=100, 1M total gates, n in {3,4,5,6}.
"""
import os, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

OUT = os.path.join(HERE, "..", "..", "graphs", "e1_time_vs_n.png")
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
    out = {}
    if not os.path.isfile(path): return out
    with open(path) as f:
        for r in csv.DictReader(f, delimiter='\t'):
            if r.get("status") != "ok": continue
            out[int(r["n"])] = float(r["max_t_ms"]) / 1000.0  # → seconds
    return out

# Castor DM: project offline time (~1000 s × n at 1M mul, d=100; Castor paper Table 1)
def offline_castor_dm_seconds(n):
    return 1000.0 * n

fig, ax = plt.subplots(figsize=(8, 6.5))
for pkey, label, color, marker in PROTOS:
    data = load(f"{BASE}/{pkey}/summary.tsv")
    if not data: continue
    ns = sorted(data.keys())
    if pkey == "async":
        ys = [data[n] + offline_castor_dm_seconds(n) for n in ns]
    else:
        ys = [data[n] for n in ns]
    ax.plot(ns, ys, marker=marker, color=color, label=label)
    # QSync annotations go BELOW the curve.
    dy = -16 if pkey == "qsync" else 9
    va = "top" if pkey == "qsync" else "bottom"
    for n, y in zip(ns, ys):
        if y >= 100:
            tag = f"{y:.0f}s"
        else:
            tag = f"{y:.1f}s"
        ax.annotate(tag, (n, y), textcoords="offset points",
                    xytext=(0, dy), ha="center", va=va, fontsize=11, color=color)

ax.set_xlabel("Number of parties")
ax.set_ylabel("End-to-end time (s)")
ax.set_xticks([3, 4, 5, 6])
ax.set_yscale("log")
# Pad headroom below (for QSync's below-curve annotations) and above.
ymin, ymax = ax.get_ylim()
ax.set_ylim(ymin / 1.6, ymax * 1.4)
ax.grid(True, which="both", alpha=0.3)
ax.legend(loc="center right", bbox_to_anchor=(0.97, 0.62), framealpha=0.9)
fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
