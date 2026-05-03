#!/usr/bin/env python3
"""Catalog all sweep/experiment runs across the workspace into a CSV.

Walks the known results roots, finds every directory that either
contains a summary.tsv or is a per-cell rep* directory with
party*.log files, and emits a row per run with: name, location,
mtime, # cells (rows in summary.tsv), # status=ok rows, # rep
subdirs, total bytes, has-summary, has-progress-log.
"""
import csv, os, sys
from pathlib import Path
from datetime import datetime

ROOTS = [
    "/root/e1_sweep/results",
    "/root/asterisk-native_root/results",
    "/root/asterisk-native_root/sweep_results",
    "/root/asterisk-native/results",
    "/root/qsync-ae/results",
]
OUT = "/root/qsync-ae/results/RUNS_CATALOG.csv"

def dir_size_bytes(p: Path) -> int:
    total = 0
    try:
        for entry in p.rglob("*"):
            if entry.is_file():
                try: total += entry.stat().st_size
                except OSError: pass
    except Exception: pass
    return total

def count_summary_rows(summary: Path):
    total = ok = 0
    try:
        with open(summary) as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                total += 1
                if row.get("status", "") == "ok":
                    ok += 1
    except Exception:
        return None, None
    return total, ok

def count_rep_dirs(p: Path) -> int:
    try:
        return sum(1 for d in p.iterdir() if d.is_dir() and d.name.startswith("rep"))
    except OSError:
        return 0

def main():
    rows = []
    for root in ROOTS:
        rp = Path(root)
        if not rp.is_dir(): continue
        for d in sorted(rp.iterdir()):
            if not d.is_dir(): continue
            if d.name.startswith("_"): continue          # skip _archive etc.
            summary = d / "summary.tsv"
            progress = d / "progress.log"
            results_json = d / "results.json"
            n_cells = n_ok = None
            if summary.is_file():
                n_cells, n_ok = count_summary_rows(summary)
            n_reps = count_rep_dirs(d)
            try: mtime = datetime.fromtimestamp(d.stat().st_mtime).isoformat(timespec="seconds")
            except OSError: mtime = ""
            rows.append({
                "name": d.name,
                "root": root,
                "mtime": mtime,
                "n_cells": n_cells if n_cells is not None else "",
                "n_ok": n_ok if n_ok is not None else "",
                "n_rep_dirs": n_reps,
                "size_bytes": dir_size_bytes(d),
                "has_summary": int(summary.is_file()),
                "has_progress_log": int(progress.is_file()),
                "has_results_json": int(results_json.is_file()),
            })
    rows.sort(key=lambda r: (r["root"], r["mtime"]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {OUT}  ({len(rows)} runs)")

if __name__ == "__main__":
    main()
