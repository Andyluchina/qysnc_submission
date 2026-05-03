#!/usr/bin/env python3
"""Aggregate run_experiments.sh summary.tsv → table + LaTeX.

Reads /root/e1_sweep/results/recovery_experiments/summary.tsv,
computes median + p10/p90 + min/max per (scenario, n), and writes
recovery_table.tex (LaTeX) + a console-friendly summary.
"""
import csv
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

TSV = Path("/root/e1_sweep/results/recovery_experiments/summary.tsv")
TEX = Path("/root/asterisk-native_root/recovery_table.tex")

SCENARIO_LABELS = {
    "s1_loss":       r"S1: packet loss",
    "s2_crash":      r"S2: crash",
    "s3_false_nack": r"S3: false NACK",
}

def main():
    if not TSV.exists():
        print(f"FATAL: {TSV} not found", file=sys.stderr); sys.exit(1)

    by_key = defaultdict(list)
    with TSV.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            try:
                ms = float(row["recovery_ms"])
            except (ValueError, KeyError):
                continue
            by_key[(row["scenario"], int(row["n"]))].append(ms)

    if not by_key:
        print("No numeric rows found in summary.tsv. Possibly all NA.", file=sys.stderr)

    # Console summary
    print(f"{'scenario':<20} {'n':>3} {'reps':>5} {'median(ms)':>12} {'p10':>8} {'p90':>8} {'min':>8} {'max':>8}")
    rows = []
    for (s, n), vals in sorted(by_key.items()):
        med = statistics.median(vals) if vals else float("nan")
        if len(vals) >= 2:
            p10 = statistics.quantiles(vals, n=10)[0] if len(vals) >= 10 else min(vals)
            p90 = statistics.quantiles(vals, n=10)[8] if len(vals) >= 10 else max(vals)
        else:
            p10 = p90 = vals[0] if vals else float("nan")
        mn = min(vals) if vals else float("nan")
        mx = max(vals) if vals else float("nan")
        print(f"{s:<20} {n:>3} {len(vals):>5} {med:>12.2f} {p10:>8.2f} {p90:>8.2f} {mn:>8.2f} {mx:>8.2f}")
        rows.append((s, n, len(vals), med, p10, p90, mn, mx))

    # LaTeX table
    TEX.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Recovery time after fault. Median over $r$ reps; min/max in brackets.}",
        r"\label{tab:recovery}",
        r"\begin{tabular}{lcccc}",
        r"\toprule",
        r"Scenario & $n$ (parties) & Reps & Median (ms) & [min, max] (ms) \\",
        r"\midrule",
    ]
    for s, n, k, med, _, _, mn, mx in rows:
        lines.append(
            f"{SCENARIO_LABELS.get(s, s)} & {n+1} & {k} & "
            f"{med:.2f} & [{mn:.2f}, {mx:.2f}] \\\\"
        )
    lines += [
        r"\bottomrule",
        r"\end{tabular}",
        r"\end{table}",
    ]
    TEX.write_text("\n".join(lines) + "\n")
    print(f"\nWrote {TEX}")

if __name__ == "__main__":
    main()
