#!/usr/bin/env python3
"""Plot recovery time per scenario × n.
X axis: number of parties (n+1).
Y axis: recovery time (ms, log scale because the three scenarios span
multiple orders of magnitude).
"""
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

TSV = Path("/root/e1_sweep/results/recovery_experiments/summary.tsv")
OUT = Path("/root/e1_sweep/results/recovery_experiments/recovery_plot.pdf")

LABELS = {
    "s1_loss":       "S1: packet loss (substrate retx)",
    "s2_crash":      "S2: crash (quorum)",
    "s3_false_nack": "S3: false-NACK (quorum)",
}
COLORS = {
    "s1_loss":       "#1f77b4",
    "s2_crash":      "#d62728",
    "s3_false_nack": "#2ca02c",
}
MARKERS = {
    "s1_loss":       "o",
    "s2_crash":      "s",
    "s3_false_nack": "^",
}

def main():
    by = defaultdict(list)
    with TSV.open() as f:
        for row in csv.DictReader(f, delimiter="\t"):
            try:
                ms = float(row["recovery_ms"])
            except (ValueError, KeyError):
                continue
            by[(row["scenario"], int(row["n"]))].append(ms)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for sc in ["s1_loss", "s2_crash", "s3_false_nack"]:
        xs = []; meds = []; mins = []; maxs = []
        for n in sorted(set(k[1] for k in by if k[0] == sc)):
            vals = by.get((sc, n), [])
            if not vals: continue
            xs.append(n + 1)   # number of parties
            meds.append(statistics.median(vals))
            mins.append(min(vals))
            maxs.append(max(vals))
        if not xs: continue
        err_low  = [m - lo for m, lo in zip(meds, mins)]
        err_high = [hi - m  for m, hi in zip(meds, maxs)]
        ax.errorbar(xs, meds, yerr=[err_low, err_high],
                    label=LABELS[sc], color=COLORS[sc],
                    marker=MARKERS[sc], markersize=8,
                    linestyle="-", linewidth=1.5,
                    capsize=4)

    ax.set_xlabel("Number of parties")
    ax.set_ylabel("Recovery latency (ms, log scale)")
    ax.set_yscale("log")
    ax.set_xticks([4, 5])
    ax.grid(True, which="both", linestyle=":", alpha=0.5)
    ax.legend(loc="upper left", fontsize=9)
    fig.tight_layout()
    fig.savefig(OUT)
    print(f"Wrote {OUT}")

if __name__ == "__main__":
    main()
