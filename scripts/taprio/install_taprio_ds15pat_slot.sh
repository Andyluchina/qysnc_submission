#!/bin/bash
# ds15-pattern taprio with parameterized slot width.
# Slot = PER_OWNER × ENTRY_NS (default 4×262136 ≈ 1.048 ms).
# Usage: install_taprio_ds15pat_slot.sh <pid> <total_hosts> <slot_ns>
set -euo pipefail
PID=$1
TOTAL=$2
SLOT_NS=$3
ANCHOR=1609731273000000000

# Pick PER_OWNER and ENTRY_NS. Keep ENTRY_NS ≤ 262144 (taprio entry max
# in some kernels is around 1ms). Use PER_OWNER = ceil(SLOT_NS/262136).
PER_OWNER=$(( (SLOT_NS + 262135) / 262136 ))
[ "$PER_OWNER" -lt 1 ] && PER_OWNER=1
ENTRY_NS=$(( SLOT_NS / PER_OWNER ))

NUM=$((PER_OWNER * TOTAL))

ENTRIES=""
for s in $(seq 0 $((NUM-1))); do
  owner=$((s / PER_OWNER))
  if [ "$owner" = "$PID" ]; then
    ENTRIES+=" sched-entry S 0x1 ${ENTRY_NS}"
  else
    ENTRIES+=" sched-entry S 0x2 ${ENTRY_NS}"
  fi
done

TX_NOW=$(ethtool -l eno1 2>/dev/null | awk '/^Current/{f=1} f && /TX:/{print $2; exit}')
if [ "${TX_NOW:-0}" -lt 2 ]; then
  sudo ethtool -L eno1 tx 4 2>/dev/null || sudo ethtool -L eno1 combined 4 2>/dev/null || true
fi

# shellcheck disable=SC2086
sudo tc qdisc replace dev eno1 parent root handle 100 taprio \
  num_tc 2 \
  map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 \
  queues 1@0 1@1 \
  base-time ${ANCHOR} \
  ${ENTRIES} \
  clockid CLOCK_TAI \
  flags 0x0
echo "pid=$PID total=$TOTAL slot=${SLOT_NS}ns (${PER_OWNER}x${ENTRY_NS}ns) cycle=$((ENTRY_NS*NUM))ns"
