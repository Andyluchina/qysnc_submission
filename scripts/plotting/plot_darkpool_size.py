#!/usr/bin/env python3
"""Darkpool CDA latency vs list size B=S, n=3 (4-party), d=7, on TSN island.
Reads the n=3 TSN single-rep summary TSVs; produces a clean log-log plot,
no title, two-entry legend (Sync TCP / QSync)."""
import os, csv
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

plt.rcParams.update({
    "font.size": 14,
    "axes.labelsize": 15,
    "xtick.labelsize": 13,
    "ytick.labelsize": 13,
    "legend.fontsize": 14,
    "lines.linewidth": 2.0,
    "lines.markersize": 8,
})

OUT = os.path.join(HERE, "..", "..", "graphs_duplicated", "darkpool_size_sweep_latency.png")

def load(path):
    by_b = defaultdict(list)
    if not os.path.isfile(path): return None
    with open(path) as f:
        for row in csv.DictReader(f, delimiter='\t'):
            try:
                b = int(row["B"]); t = float(row["max_t_ms"])
                if t > 0: by_b[b].append(t)
            except (ValueError, KeyError):
                continue
    return by_b if by_b else None

def median_minmax(xs):
    s = sorted(xs)
    return s[len(s)//2], s[0], s[-1]

fig, ax = plt.subplots(figsize=(7.5, 5))
for label, key, color, mark in [
    ("Sync TCP", "sync",  "#1f77b4", "o"),
    ("QSync",    "qsync", "#2ca02c", "^"),
]:
    by_b = load(os.path.join(HERE, "..", "..", "results", "darkpool_size_sweep_n3_tsn", key, "summary.tsv"))
    if not by_b: continue
    bs = sorted(by_b.keys())
    meds = []; los = []; his = []
    for b in bs:
        m, lo, hi = median_minmax(by_b[b])
        meds.append(m); los.append(m - lo); his.append(hi - m)
    ax.errorbar(bs, meds, yerr=[los, his], marker=mark, color=color, capsize=3, label=label)

ax.set_xscale("log"); ax.set_yscale("log")
ax.set_xlabel("List size B = S")
ax.set_ylabel("Latency per matching (ms)")
ax.grid(True, which="both", alpha=0.3)
ax.legend(loc="best")
fig.tight_layout()
fig.savefig(OUT, dpi=140)
print(f"wrote {OUT}")
