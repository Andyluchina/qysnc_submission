#!/usr/bin/env python3
"""Darkpool list-size sweep on TSN island (n=3, d=7 for CDA, d=6 for VM).
Two separate figures, one per app, each with sync vs qsync lines."""
import os, csv
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SUMMARY = "/root/e1_sweep/results/darkpool_size_sweep_tsn/summary.tsv"

def load_grouped(path):
    """Returns dict[(app, protocol)][B] = [list of latency_ms]. status=ok only."""
    out = defaultdict(lambda: defaultdict(list))
    if not os.path.isfile(path):
        return out
    with open(path) as f:
        for row in csv.DictReader(f, delimiter='\t'):
            if row.get("status") != "ok":
                continue
            try:
                b = int(row["B"]); t = float(row["max_t_ms"])
                if t > 0:
                    out[(row["app"], row["protocol"])][b].append(t)
            except (ValueError, KeyError):
                continue
    return out

def median_minmax(xs):
    s = sorted(xs)
    return s[len(s)//2], s[0], s[-1]

def plot_one(app_label, app_key, data, depth, out_path):
    fig, ax = plt.subplots(figsize=(7.5, 5))
    for proto_label, proto_key, color, mark in [
        ("Sync TCP (TSN fabric)", "sync",  "#1f77b4", "o"),
        ("QSync (TSN + Qbv)",     "qsync", "#2ca02c", "^"),
    ]:
        series = data.get((app_key, proto_key))
        if not series:
            print(f"  no data for {app_key}/{proto_key}")
            continue
        bs = sorted(series.keys())
        meds, los, his = [], [], []
        for b in bs:
            m, lo, hi = median_minmax(series[b])
            meds.append(m); los.append(m - lo); his.append(hi - m)
        ax.errorbar(bs, meds, yerr=[los, his], marker=mark, color=color,
                    capsize=3, label=f"{proto_label} (n={len(series[bs[0]])} reps)")
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("List size B = S")
    ax.set_ylabel("Latency per matching (ms)")
    ax.set_title(f"Dark-pool {app_label}: latency vs. list size (n=3, d={depth})")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="best")
    fig.tight_layout()
    fig.savefig(out_path, dpi=140)
    print(f"wrote {out_path}")

if __name__ == "__main__":
    data = load_grouped(SUMMARY)
    plot_one("CDA", "Darkpool_CDA", data, 7,
             "/root/e1_sweep/results/darkpool_size_sweep_tsn_cda.png")
    plot_one("VM",  "Darkpool_VM",  data, 6,
             "/root/e1_sweep/results/darkpool_size_sweep_tsn_vm.png")
