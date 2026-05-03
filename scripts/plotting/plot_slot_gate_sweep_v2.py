#!/usr/bin/env python3
"""Fig 4: throughput vs slot σ at n=5, d=100, three gate counts."""
import os, csv
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

OUT = os.path.join(HERE, "..", "..", "graphs", "slot_gate_sweep_throughput.png")
PATH = os.path.join(HERE, "..", "..", "results", "slot_sweep_n4", "summary.tsv")

plt.rcParams.update({
    "font.size": 13, "axes.titlesize": 14, "axes.labelsize": 13,
    "xtick.labelsize": 12, "ytick.labelsize": 12, "legend.fontsize": 12,
    "axes.linewidth": 1.2, "lines.linewidth": 2.4, "lines.markersize": 9,
})

GMAP = {1_000_000: ("1.0 M gates", "#1f77b4", "o"),
        1_500_000: ("1.5 M gates", "#2ca02c", "^"),
        2_000_000: ("2.0 M gates", "#d62728", "s")}

data = defaultdict(dict)  # gates_total -> {slot_ms: thr}
if os.path.isfile(PATH):
    with open(PATH) as f:
        for r in csv.DictReader(f, delimiter='\t'):
            if r.get("status") != "ok": continue
            data[int(r["gates_total"])][float(r["slot_ms"])] = float(r["throughput_mul_s"])

fig, ax = plt.subplots(figsize=(8, 6.5))
for g, (label, color, marker) in GMAP.items():
    if g not in data: continue
    slots = sorted(data[g].keys())
    ys = [data[g][s]/1000 for s in slots]
    ax.plot(slots, ys, marker=marker, color=color, label=label)

# Selective annotations: group y-values that are within THRESH (k mul/s) at the
# same σ into one combined label. Reduces clutter when curves nearly overlap.
THRESH = 0.5
slots_set = sorted({s for d in data.values() for s in d.keys()})
for s in slots_set:
    points = []  # (y, color)
    for g, (label, color, marker) in GMAP.items():
        if g in data and s in data[g]:
            points.append((data[g][s]/1000, color))
    points.sort()
    clusters = [[points[0]]] if points else []
    for p in points[1:]:
        if p[0] - clusters[-1][-1][0] < THRESH:
            clusters[-1].append(p)
        else:
            clusters.append([p])
    for cl in clusters:
        ys_in = [p[0] for p in cl]
        center = sum(ys_in) / len(ys_in)
        if len(cl) == 1:
            tag = f"{ys_in[0]:.0f}k"
            color = cl[0][1]
        else:
            tag = f"~{round(center):.0f}k"
            color = "#444"
        ax.annotate(tag, (s, center), textcoords="offset points",
                    xytext=(0, 10), ha="center", fontsize=11, color=color)

ax.set_xlabel("TDMA slot σ (ms)")
ax.set_ylabel("Throughput (k mul/s)")
ax.set_xticks([1, 2, 5, 10])
# Zoom y tight to the data range so the per-curve differences fill the plot.
ymin = min(min(d.values()) for d in data.values()) / 1000
ymax = max(max(d.values()) for d in data.values()) / 1000
pad = max(1.0, (ymax - ymin) * 0.30)
ax.set_ylim(ymin - pad, ymax + pad)
ax.grid(True, alpha=0.3)
ax.legend(loc="best", framealpha=0.9)
fig.tight_layout()
fig.savefig(OUT, dpi=150)
print(f"wrote {OUT}")
