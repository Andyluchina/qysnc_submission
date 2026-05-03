#!/bin/bash
# Port-confined taprio for eno1.
# Design: tc 0 = always-open (default-priority traffic — SSH, NTP, DNS, etc.);
# tc 1 = MPC-traffic-only, gated to this host's owner slot. The MPC binary
# tags its UDP broadcast socket with SO_PRIORITY=4 (see bcast_bus.cpp), and
# our map sends priority 4 → tc 1; everything else → tc 0.
#
# Slot layout: 4 entries × 262,136 ns per host (slot ≈ 1.048 ms), cycle =
# total_hosts × 4 × 262,136 ns.
# Schedule: gatemask 0x03 (both tcs open) during owner's slot, gatemask 0x01
# (only tc 0 = SSH/etc.) during all other slots.
#
# Usage:
#   setup_taprio_eno1.sh <pid> <total_hosts> [anchor_ns]
#   setup_taprio_eno1.sh remove
#
# Atomic: uses `tc qdisc replace` so old qdisc is replaced in one step, no
# transient "no qdisc" window that could disrupt SSH.
set -euo pipefail

CMD=${1:-?}
IF=eno1

if [ "$CMD" = "remove" ]; then
  # Don't actually del — replace with mq so we never leave the interface
  # without a qdisc. (Pure `del root` left ds26 unreachable in the past.)
  sudo tc qdisc replace dev $IF root mq 2>/dev/null || true
  echo "taprio replaced with mq on $IF"
  exit 0
fi

PID=${1}
TOTAL_HOSTS=${2:-4}
ANCHOR_NS=${3:-1609731273000000000}

if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: pid must be a non-negative integer, got '$PID'" >&2; exit 3
fi
if ! [[ "$TOTAL_HOSTS" =~ ^[0-9]+$ ]] || [ "$TOTAL_HOSTS" -lt 2 ]; then
  echo "ERROR: total_hosts must be an integer >= 2, got '$TOTAL_HOSTS'" >&2; exit 3
fi
if [ "$PID" -ge "$TOTAL_HOSTS" ]; then
  echo "ERROR: pid $PID is out of range for total_hosts=$TOTAL_HOSTS (0..$((TOTAL_HOSTS-1)))" >&2; exit 3
fi

ENTRY_NS=262136
ENTRIES_PER_OWNER=4
NUM_ENTRIES=$(( ENTRIES_PER_OWNER * TOTAL_HOSTS ))
CYCLE_NS=$(( ENTRY_NS * NUM_ENTRIES ))

# Build schedule:
#   owner slot   → gatemask 0x03 (tc 0 + tc 1 both open)
#   non-owner    → gatemask 0x01 (only tc 0 open)
# tc 0 is therefore always open (SSH/etc. unaffected).
ENTRIES=""
for s in $(seq 0 $((NUM_ENTRIES-1))); do
  owner=$(( s / ENTRIES_PER_OWNER ))
  if [ "$owner" = "$PID" ]; then
    ENTRIES+=" sched-entry S 0x03 ${ENTRY_NS}"
  else
    ENTRIES+=" sched-entry S 0x01 ${ENTRY_NS}"
  fi
done

# Bump TX queues if the NIC reports < 2 (taprio with num_tc=2 needs 2 queues).
TX_NOW=$(ethtool -l $IF 2>/dev/null | awk '/^Current/{f=1} f && /TX:/{print $2; exit}')
if [ "${TX_NOW:-0}" -lt 2 ]; then
  echo "bumping $IF TX queues from ${TX_NOW:-?} to 4"
  sudo ethtool -L $IF tx 4 2>/dev/null || sudo ethtool -L $IF combined 4 2>/dev/null || true
fi

echo "installing port-confined taprio on $IF (PID=$PID/total=$TOTAL_HOSTS,"
echo "  ${NUM_ENTRIES}×${ENTRY_NS}ns = cycle ${CYCLE_NS}ns ≈ $((CYCLE_NS / 1000))µs,"
echo "  schedule: 0x03 owner-slot (${ENTRIES_PER_OWNER}×${ENTRY_NS}ns), 0x01 elsewhere,"
echo "  map: priority 4 (MPC) → tc 1; everything else → tc 0,"
echo "  anchor=${ANCHOR_NS})"
# Map: position N is the tc index for skb priority N.
# Priorities 0..3 → tc 0; priority 4 → tc 1; priorities 5..15 → tc 0.
# This isolates the MPC SO_PRIORITY=4 traffic into the gated tc 1.
# shellcheck disable=SC2086
sudo tc qdisc replace dev $IF parent root handle 100 taprio \
  num_tc 2 \
  map 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 \
  queues 1@0 1@1 \
  base-time ${ANCHOR_NS} \
  ${ENTRIES} \
  clockid CLOCK_TAI \
  flags 0x0
# Larger pfifo limits to absorb burst traffic during gate-closed periods.
for tc_minor in 1 2 3 4; do
  sudo tc qdisc replace dev $IF parent 100:$tc_minor pfifo limit 100000 2>/dev/null || true
done
echo "installed:"
tc qdisc show dev $IF | head -5
