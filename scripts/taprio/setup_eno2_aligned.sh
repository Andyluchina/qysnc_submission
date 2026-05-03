#!/bin/bash
# Install eno2 taprio aligned to TSN switch base-time, with SSH-safe REAL TDMA gate.
# 4 honest hosts, 1 slot each at σ=1.048544 ms, cycle = 4 × σ = 4.194176 ms.
# own slot gate 0x3 (tc0+tc1 open) ; other slots 0x1 (tc0 / SSH only).
# base-time = 1609731273000000000 ns (matches the switch's Qbv reference).
set -u

SLOT_NS=1048544
TOTAL=4
ALL=("ds26" "ds15" "ds16" "ds17")
BASE=1609731273000000000

for pid in 0 1 2 3; do
  h=${ALL[$pid]}
  entries=""
  for s in 0 1 2 3; do
    if [ "$s" = "$pid" ]; then entries+=" sched-entry S 0x3 ${SLOT_NS}"
    else entries+=" sched-entry S 0x1 ${SLOT_NS}"; fi
  done
  cmd="sudo tc qdisc replace dev eno2 parent root handle 100 taprio num_tc 2 map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 queues 1@0 1@1 base-time $BASE $entries clockid CLOCK_TAI flags 0x0"
  if [ "$h" = "ds26" ]; then bash -c "$cmd"
  else ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" "$cmd"; fi
done

echo
echo "=== verify base-time / cycle / per-host gate scheme ==="
for h in "${ALL[@]}"; do
  if [ "$h" = "ds26" ]; then sched=$(tc qdisc show dev eno2)
  else sched=$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "tc qdisc show dev eno2"); fi
  base=$(echo "$sched" | grep -oE "base-time [0-9]+" | head -1)
  cycle=$(echo "$sched" | grep -oE "cycle-time [0-9]+" | head -1)
  own=$(echo "$sched" | awk '/index [0-9]+ cmd S gatemask 0x3/{print $2; exit}')
  echo "  $h: $base $cycle  own_slot_index=${own:-MISSING}"
done

echo
echo "=== SSH probe (must still work) ==="
for h in ds15 ds16 ds17; do
  out=$(timeout 5 ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" "echo SSH_OK" 2>&1)
  echo "  $h: $out"
done
