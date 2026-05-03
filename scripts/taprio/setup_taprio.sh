#!/bin/bash
# Install software taprio (flags=0x0) on eno2 matching the TSN switch
# schedule: 16 entries × 262136 ns, total cycle 4194176 ns.
# Each host owns 4 contiguous entries (4 × 262136 ≈ 1.048 ms).
# Owner mapping: P0 = entries 0-3, P1 = 4-7, P2 = 8-11, P3 = 12-15.
#
# Usage:
#   ./setup_taprio.sh <pid> <anchor_ns>     # install for this PID
#   ./setup_taprio.sh remove                # tear down (revert to default mq)
#
#   pid       — this host's party id (0..3); maps to which 4 entries are open
#   anchor_ns — switch-shared base-time in CLOCK_TAI ns (read from /tmp/tsn_anchor.txt)
#
# Background:
#   - Broadcom BCM5720 with tg3 has hw-tc-offload=off [fixed], so we use
#     software taprio (flags 0x0). Kernel hrtimer-based release; ~10-50 µs
#     jitter under typical load, fine against a 1.048 ms slot.
#   - num_tc=2: tc 0 = MPC traffic (gated), tc 1 = control / non-MPC (always open)
#   - All MPC sockets must call setsockopt(SO_PRIORITY, 0) to land in tc 0.
#   - Stage A4 decided app-level TDMA must be OFF when taprio is on
#     (TDMA_DISABLED=1) — the kernel does the gating now.
set -euo pipefail

CMD=${1:-?}

if [ "$CMD" = "remove" ]; then
  sudo tc qdisc replace dev eno2 root mq 2>/dev/null || sudo tc qdisc del dev eno2 root 2>/dev/null || true
  echo "taprio removed; eno2 back to default qdisc"
  tc -d qdisc show dev eno2 | head
  exit 0
fi

PID=${1}
ANCHOR_NS=${2:-}

if [ -z "$ANCHOR_NS" ]; then
  if [ -f /tmp/tsn_anchor.txt ]; then
    ANCHOR_NS=$(awk -F= '/^ANCHOR_NS=/ {print $2}' /tmp/tsn_anchor.txt)
  fi
fi
if [ -z "$ANCHOR_NS" ]; then
  echo "ERROR: anchor_ns not provided and /tmp/tsn_anchor.txt missing" >&2
  exit 2
fi

case "$PID" in
  0|1|2|3) ;;
  *) echo "ERROR: pid must be 0..3, got '$PID'" >&2; exit 3 ;;
esac

ENTRY_NS=262136          # 262.136 µs per entry (switch SupportedIntervalMax for 16 entries)
NUM_ENTRIES=16
CYCLE_NS=$(( ENTRY_NS * NUM_ENTRIES ))    # 4194176 ns

# Defensive: round the supplied anchor down to a multiple of CYCLE_NS.
# App TDMA computes slot via `now mod cycle` (assumes phase=0); kernel
# taprio computes via `(now - base_time) mod cycle`. They agree only
# when `base_time mod cycle == 0`. A bad anchor (e.g., the historical
# 1609731273000000000 ns from /tmp/tsn_anchor.txt, which evaluates to
# 4047488 ns mod 4194176 ns ≈ 4 slots out of phase) puts app and
# kernel ~3 slots out of phase and the protocol deadlocks under TDMA.
ANCHOR_REM=$(( ANCHOR_NS % CYCLE_NS ))
if [ "$ANCHOR_REM" -ne 0 ]; then
  ANCHOR_OLD=$ANCHOR_NS
  ANCHOR_NS=$(( ANCHOR_NS - ANCHOR_REM ))
  echo "anchor_ns=$ANCHOR_OLD has remainder $ANCHOR_REM mod cycle; rounding to $ANCHOR_NS"
fi

# Build sched-entries: gate=0x01 on this PID's 4 owned entries, gate=0x02 elsewhere
ENTRIES=""
for s in $(seq 0 $((NUM_ENTRIES-1))); do
  owner=$(( s / 4 ))
  if [ "$owner" = "$PID" ]; then
    ENTRIES+=" sched-entry S 0x01 ${ENTRY_NS}"
  else
    ENTRIES+=" sched-entry S 0x02 ${ENTRY_NS}"
  fi
done

# taprio with num_tc=2 needs at least 2 TX queues. tg3 defaults to 1;
# the BCM5720 supports up to 4. Bump if needed (idempotent).
TX_NOW=$(ethtool -l eno2 2>/dev/null | awk '/^Current/{f=1} f && /TX:/{print $2; exit}')
if [ "${TX_NOW:-0}" -lt 2 ]; then
  echo "bumping eno2 TX queues from ${TX_NOW:-?} to 4"
  sudo ethtool -L eno2 tx 4
fi

echo "installing taprio on eno2 (PID=$PID, anchor=${ANCHOR_NS}, cycle=${CYCLE_NS}ns)"

# shellcheck disable=SC2086
sudo tc qdisc replace dev eno2 parent root handle 100 taprio \
  num_tc 2 \
  map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 \
  queues 1@0 1@1 \
  base-time ${ANCHOR_NS} \
  ${ENTRIES} \
  clockid CLOCK_TAI \
  flags 0x0

echo "installed; current qdisc:"
tc -d qdisc show dev eno2 | head -30
echo "stats:"
tc -s qdisc show dev eno2 | head -20
