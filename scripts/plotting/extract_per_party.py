#!/usr/bin/env python3
"""Walk darkpool_size_sweep_tsn results, emit per-party TSV."""
import os, re, sys, glob

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/root/e1_sweep/results/darkpool_size_sweep_tsn"
OUT  = os.path.join(ROOT, "per_party.tsv")

# rep1_qsync_Darkpool_VM_B256
NAME_RE = re.compile(r"^rep(\d+)_(sync|qsync)_(Darkpool_(?:CDA|VM))_B(\d+)$")
TIME_RE  = re.compile(r"^time:\s*([\d.]+)")
SENT_RE  = re.compile(r"^sent:\s*(\d+)")
DEPTH_RE = re.compile(r"^Depth:\s*(\d+)")
TOTAL_RE = re.compile(r"^Total:\s*(\d+)")

def parse_party_log(path):
    """Returns dict with last time_ms, bytes_sent, depth, total. None on no time."""
    out = {"time_ms": None, "bytes_sent": None, "depth": None, "total": None}
    if not os.path.isfile(path):
        return out
    with open(path) as f:
        for line in f:
            m = TIME_RE.match(line)
            if m: out["time_ms"] = float(m.group(1))
            m = SENT_RE.match(line)
            if m: out["bytes_sent"] = int(m.group(1))
            m = DEPTH_RE.match(line)
            if m and out["depth"] is None: out["depth"] = int(m.group(1))
            m = TOTAL_RE.match(line)
            if m and out["total"] is None: out["total"] = int(m.group(1))
    return out

rows = []
for entry in sorted(os.listdir(ROOT)):
    full = os.path.join(ROOT, entry)
    if not os.path.isdir(full): continue
    m = NAME_RE.match(entry)
    if not m: continue
    rep, proto, app, B = int(m.group(1)), m.group(2), m.group(3), int(m.group(4))
    for pid in range(4):  # n=3 → P0..P3
        info = parse_party_log(os.path.join(full, f"party{pid}.log"))
        rows.append({
            "rep": rep, "app": app, "protocol": proto, "B": B, "S": B,
            "n": 3, "party": pid,
            "time_ms": info["time_ms"] if info["time_ms"] is not None else "",
            "bytes_sent": info["bytes_sent"] if info["bytes_sent"] is not None else "",
            "depth": info["depth"] if info["depth"] is not None else "",
            "total_gates": info["total"] if info["total"] is not None else "",
            "status": "ok" if info["time_ms"] is not None else "missing",
        })

if not rows:
    print(f"no result dirs found in {ROOT}", file=sys.stderr)
    sys.exit(1)

cols = ["rep", "app", "protocol", "B", "S", "n", "party",
        "time_ms", "bytes_sent", "depth", "total_gates", "status"]
with open(OUT, "w") as f:
    f.write("\t".join(cols) + "\n")
    for r in rows:
        f.write("\t".join(str(r[c]) for c in cols) + "\n")

n_ok = sum(1 for r in rows if r["status"] == "ok")
print(f"wrote {OUT}: {len(rows)} party-records, {n_ok} with time")
print()
print("--- preview (first 12) ---")
print("\t".join(cols))
for r in rows[:12]:
    print("\t".join(str(r[c]) for c in cols))
