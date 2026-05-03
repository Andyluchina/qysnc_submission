#!/usr/bin/env python3
"""Fig 0 motivation: 2x3 grid, online phase only, n=3.
Cols: Asterisk (sync TCP, eno1 bare), QSync (this work, eno2 TSN), Castor (async HM, eno1 bare)
Rows: Normal, Malicious flooding attack
X: total gates (M); Y: throughput (k mul/s) starting at 0.
"""
import os, csv
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

OUT = os.path.join(HERE, "..", "..", "graphs", "motivation_v2.png")
BASE = os.path.join(HERE, "..", "..", "results", "motivation_v2")

# Sharp/large fonts
plt.rcParams.update({
    "font.size": 8,
    "axes.titlesize": 9,
    "axes.labelsize": 8,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "legend.fontsize": 7,
    "figure.titlesize": 10,
    "axes.linewidth": 0.8,
    "lines.linewidth": 1.3,
    "lines.markersize": 4,
})

def load(path):
    by_g = defaultdict(list)
    if not os.path.isfile(path): return None
    projected = False
    with open(path) as f:
        for row in csv.DictReader(f, delimiter='\t'):
            status = row.get("status", "")
            if status not in ("ok", "projected"):
                continue
            if status == "projected":
                projected = True
            try:
                g = int(row["gates_total"])
                t = float(row["throughput_mul_s"])
                if t > 0: by_g[g].append(t)
            except (ValueError, KeyError):
                continue
    if not by_g: return None
    xs = sorted(by_g.keys())
    ys = [sorted(by_g[g])[len(by_g[g])//2] for g in xs]
    return xs, ys, projected

COLS = [
    ("sync",  "Asterisk (sync)",            "#1f77b4", "o"),
    ("qsync", "QSync-MPC (quasi-sync)",      "#2ca02c", "^"),
    ("async", "Castor (async)",              "#d62728", "s"),
]
ROWS = [("normal", "Normal"), ("flood", "Under malicious flooding")]

fig, axs = plt.subplots(2, 3, figsize=(6, 3.2), sharex=True, sharey="row")

# Use a single global y-max so the rows are visually comparable (collapse stays visible).
global_max = 0
for ri, (rkey, _) in enumerate(ROWS):
    for ckey, _, _, _ in COLS:
        d = load(f"{BASE}/{ckey}_{rkey}/summary.tsv")
        if d:
            global_max = max(global_max, max(d[1]))
ymax = (global_max * 1.10 / 1000) if global_max > 0 else 1.0

for ri, (rkey, rlabel) in enumerate(ROWS):
    for ci, (ckey, clabel, color, marker) in enumerate(COLS):
        ax = axs[ri, ci]
        d = load(f"{BASE}/{ckey}_{rkey}/summary.tsv")
        if d:
            xs, ys, _ = d
            xs_m = [x/1e6 for x in xs]
            ys_k = [y/1000 for y in ys]
            ax.plot(xs_m, ys_k, marker=marker, color=color, linestyle="-", label=clabel)
            # qsync gets annotations below the curve; other protocols above.
            if ckey == "qsync":
                ann_xy, ann_va = (0, -8), "top"
            else:
                ann_xy, ann_va = (0, 5), "bottom"
            for x, y in zip(xs_m, ys_k):
                if y < 0.1:
                    lbl = "0k"
                elif y < 1:
                    lbl = f"{y:.2f}".rstrip("0").rstrip(".") + "k"
                else:
                    lbl = f"{y:.0f}k"
                ann_fs = 5 if ckey == "async" else 6
                ax.annotate(lbl, (x, y), textcoords="offset points",
                            xytext=ann_xy, ha="center", va=ann_va,
                            fontsize=ann_fs, color=color)
        else:
            ax.text(0.5, 0.5, "(no data)", transform=ax.transAxes,
                    ha="center", va="center", color="gray", fontsize=13)
        ax.set_ylim(0, ymax)
        ax.grid(True, alpha=0.3)
        if ri == 0:
            ax.set_title(clabel, fontsize=7)
        if ri == len(ROWS)-1:
            ax.set_xlabel("Total gates (M)")
        if ci == 0:
            ax.set_ylabel(f"{rlabel}\nThroughput (k mul/s)", fontsize=6)
        # Per-subplot legend removed — column headers already say protocol name.

fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
