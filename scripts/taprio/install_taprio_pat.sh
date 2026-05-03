#!/bin/bash
# Install owner-slot pattern taprio on a host's eno1.
#   map: 0 1 1 1 1 ... → priority 0 → tc0, prio 1..15 → tc1
#   gatemask 0x1 (tc0) on owner slot (4× 262136 ns), 0x2 (tc1) on others.
# Usage: install_taprio_pat.sh <pid> <total_hosts>
set -euo pipefail
PID=$1
TOTAL=$2
ANCHOR=1609731273000000000
ENTRY_NS=262136
PER_OWNER=4
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

# Ensure >= 2 TX queues
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
echo "host pid=$PID total=$TOTAL cycle=$((ENTRY_NS*NUM))ns installed"
