#!/bin/bash
# QSync (TSN) Darkpool launcher. n=3 fixed (4 hosts P0..P3 on the TSN
# island). Selects between Darkpool_CDA and Darkpool_VM via APP env var.
#
#   Usage: APP=Darkpool_CDA|Darkpool_VM ./run_darkpool_tsn.sh <B> <S> <repeat> <out_dir>
#     B/S    = buy/sell list size
#     repeat = -r flag (matchings inside one MPC session)
#     out_dir = where party logs land

set -u

APP=${APP:-Darkpool_CDA}
B=$1
S=$2
REPEAT=$3
OUT=$4

LOCAL_ROOT=/root/asterisk-native_root
REMOTE_ROOT=/tmp/asterisk-native_root
NET_CONFIG=/tmp/asterisk_bundle/net_config_n3_tsn.json

mkdir -p "$OUT"

N=3
HOSTS=("" "ds15" "ds16" "ds17")
THREADS=${THREADS:-6}
THREADS_P0=${THREADS_P0:-$THREADS}

# eno2 PHC
TIMESRC_BACKEND=ptp
TIMESRC_PTP_DEV=/dev/ptp1

# TDMA: app-cooperative gate matching switch Qbv + kernel taprio.
# Default slot = 4 × 262136 ns = 1,048,544 ns; cycle = 4 × slot = 4,194,176 ns.
TDMA_SLOT_NS=${TDMA_SLOT_NS:-1048544}
TDMA_GUARD_NS=${TDMA_GUARD_NS:-0}

# BcastBus knobs — must be consistent across all hosts on the TSN subnet.
MPC_SO_PRIORITY=${MPC_SO_PRIORITY:-4}
MPC_BROADCAST_IP=${MPC_BROADCAST_IP:-192.168.1.255}
MPC_PAIR_KEY_SEED=${MPC_PAIR_KEY_SEED:-200}
TDMA_DISABLED=${TDMA_DISABLED:-}

bcast_envs() {
  echo -n "MPC_SO_PRIORITY=$MPC_SO_PRIORITY MPC_BROADCAST_IP=$MPC_BROADCAST_IP MPC_PAIR_KEY_SEED=$MPC_PAIR_KEY_SEED "
}

ssh_retry() {
  local host=$1; shift; local i
  for i in 1 2 3 4 5 6; do
    timeout 8 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@" && return 0
    sleep 1
  done; return 1
}

ssh_retry_bg() {
  local host=$1; shift; local i
  for i in 1 2 3 4 5 6; do
    timeout 600 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@"
    local rc=$?
    if [ $rc -ne 255 ] && [ $rc -ne 124 ]; then return $rc; fi
    sleep 1
  done; return 1
}

cleanup_all() {
  pkill -9 -x $APP 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true
  for h in ds15 ds16 ds17; do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" "pkill -9 -x $APP 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" &
  done
  wait
  sleep 1
}

cleanup_all

echo "=== qsync(TSN) $APP n=$N B=$B S=$S r=$REPEAT slot_ns=$TDMA_SLOT_NS ==="

# Start timesrcd (eno2 PHC) on every active host. Track PIDs separately so
# we can wait specifically on MPC parties without blocking on these tunnels.
TIMESRCD_PIDS=()
for h in "${HOSTS[@]:1}"; do
  ssh_retry_bg "$h" "LD_LIBRARY_PATH=$REMOTE_ROOT/lib $REMOTE_ROOT/build/timesrcd/timesrcd --unlink --backend=$TIMESRC_BACKEND --ptp-dev=$TIMESRC_PTP_DEV > /tmp/timesrcd.log 2>&1" &
  TIMESRCD_PIDS+=($!)
done
"$LOCAL_ROOT/build/timesrcd/timesrcd" --unlink --backend=$TIMESRC_BACKEND --ptp-dev=$TIMESRC_PTP_DEV > "$OUT/timesrcd_local.log" 2>&1 &
LOCAL_TIMESRCD_PID=$!
sleep 0.5

# Launch P1..P3 on remote hosts
PARTY_PIDS=()
for pid in 1 2 3; do
  host=${HOSTS[$pid]}
  ssh_retry_bg "$host" "$(bcast_envs)TDMA_SLOT_NS=$TDMA_SLOT_NS TDMA_GUARD_NS=$TDMA_GUARD_NS TDMA_DISABLED=$TDMA_DISABLED LD_LIBRARY_PATH=$REMOTE_ROOT/lib $REMOTE_ROOT/build/benchmarks/$APP -p $pid --net-config $NET_CONFIG -b $B -s $S -n $N -r $REPEAT -t $THREADS 2>&1" \
    > "$OUT/party${pid}.log" &
  PARTY_PIDS+=($!)
done

# Launch P0 locally
env $(bcast_envs)TDMA_SLOT_NS=$TDMA_SLOT_NS TDMA_GUARD_NS=$TDMA_GUARD_NS TDMA_DISABLED=$TDMA_DISABLED \
  "$LOCAL_ROOT/build/benchmarks/$APP" \
  -p 0 --net-config $NET_CONFIG -b $B -s $S -n $N -r $REPEAT -t $THREADS_P0 \
  > "$OUT/party0.log" 2>&1 &
PARTY_PIDS+=($!)

wait "${PARTY_PIDS[@]}"

# Cleanup timesrcd: kill remote daemons via ssh, kill the local daemon, then
# kill the ssh-tunnel subshells that kept them alive. Wait only on the ssh
# cleanup pids so we never block on the still-running daemons themselves.
CLEANUP_PIDS=()
for h in "${HOSTS[@]:1}"; do
  ssh -o BatchMode=yes -o ConnectTimeout=3 $h 'pkill -TERM timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true' &
  CLEANUP_PIDS+=($!)
done
kill "$LOCAL_TIMESRCD_PID" 2>/dev/null
pkill -TERM timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true
wait "${CLEANUP_PIDS[@]}" 2>/dev/null
kill "${TIMESRCD_PIDS[@]}" 2>/dev/null

echo "=== per-party result ==="
for pid in 0 1 2 3; do
  t=$(grep -E "^time:" "$OUT/party${pid}.log" 2>/dev/null | tail -1)
  echo "  P$pid: $t"
done
