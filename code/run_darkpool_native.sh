#!/bin/bash
# Quasi-sync (UDP+TDMA) launcher for Darkpool_CDA / Darkpool_VM, modeled
# on run_native.sh. Knobs: APP=Darkpool_CDA|Darkpool_VM, B/S list sizes,
# REPEAT, N (paper-n).
#
#   Usage: APP=Darkpool_CDA ./run_darkpool_native.sh <B> <S> <repeat> <n>
set -u

LOCAL_ROOT=/root/asterisk-native-non_tsn
REMOTE_ROOT=/tmp/asterisk-native-non_tsn
NET_CONFIG=/tmp/asterisk_bundle/net_config_eno1.json
RESULTS=$LOCAL_ROOT/results

APP=${APP:-Darkpool_CDA}
B=${1:-16}
S=${2:-16}
REPEAT=${3:-1}
N=${4:-5}

HOSTS=("" "server1" "server2" "server3" "server4" "server5" "server6")

TIMESRC_BACKEND=${TIMESRC_BACKEND:-fake}
TIMESRC_WARMUP_MS=${TIMESRC_WARMUP_MS:-500}
TIMESRC_PTP_DEV=${TIMESRC_PTP_DEV:-/dev/ptp0}

TDMA_DISABLED=${TDMA_DISABLED-1}
TDMA_SLOT_NS=${TDMA_SLOT_NS:-10000000}
TDMA_SCHEDULE=${TDMA_SCHEDULE:-}
TDMA_RETX_K_SEND=${TDMA_RETX_K_SEND:-}
TDMA_RETX_K_RECV=${TDMA_RETX_K_RECV:-}
TDMA_RETX_DISABLED=${TDMA_RETX_DISABLED:-}

THREADS=${THREADS:-6}
THREADS_P0=${THREADS_P0:-$THREADS}

tdma_env() {
  local out=""
  [ -n "$TDMA_DISABLED" ] && out+="TDMA_DISABLED=$TDMA_DISABLED "
  [ -n "$TDMA_SLOT_NS" ] && out+="TDMA_SLOT_NS=$TDMA_SLOT_NS "
  [ -n "$TDMA_SCHEDULE" ] && out+="TDMA_SCHEDULE=$TDMA_SCHEDULE "
  [ -n "$TDMA_RETX_K_SEND" ] && out+="TDMA_RETX_K_SEND=$TDMA_RETX_K_SEND "
  [ -n "$TDMA_RETX_K_RECV" ] && out+="TDMA_RETX_K_RECV=$TDMA_RETX_K_RECV "
  [ -n "$TDMA_RETX_DISABLED" ] && out+="TDMA_RETX_DISABLED=$TDMA_RETX_DISABLED "
  # BcastBus knobs — must be consistent across all hosts.
  [ -n "${MPC_SO_PRIORITY-}" ] && out+="MPC_SO_PRIORITY=$MPC_SO_PRIORITY "
  [ -n "${MPC_BROADCAST_IP-}" ] && out+="MPC_BROADCAST_IP=$MPC_BROADCAST_IP "
  [ -n "${MPC_PAIR_KEY_SEED-}" ] && out+="MPC_PAIR_KEY_SEED=$MPC_PAIR_KEY_SEED "
  echo -n "$out"
}

mkdir -p "$RESULTS"

ACTIVE_HOSTS=()
for ((p=1; p<=N; p++)); do ACTIVE_HOSTS+=("${HOSTS[$p]}"); done

ssh_retry() { local host=$1; shift; local i
  for i in 1 2 3 4 5 6 7 8; do
    timeout 8 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@" && return 0
    sleep 1
  done; return 1
}
ssh_retry_bg() { local host=$1; shift; local i
  for i in 1 2 3 4 5 6 7 8; do
    timeout 600 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@"
    local rc=$?; if [ $rc -ne 255 ] && [ $rc -ne 124 ]; then return $rc; fi
    sleep 1
  done; return 1
}

echo "=== qsync $APP B=$B S=$S r=$REPEAT n=$N tdma=$([ -n "$TDMA_DISABLED" ] && echo off || echo "slot=${TDMA_SLOT_NS}ns") ==="

for h in "${ACTIVE_HOSTS[@]}"; do
  ssh_retry "$h" "pkill -9 -x $APP 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" &
done
wait
pkill -9 -x "$APP" 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc
sleep 1

echo "--- starting timesrcd (backend=$TIMESRC_BACKEND) ---"
"$LOCAL_ROOT/build/timesrcd/timesrcd" --unlink \
    --backend="$TIMESRC_BACKEND" --ptp-dev="$TIMESRC_PTP_DEV" \
    > "$RESULTS/timesrcd_local.log" 2>&1 &
LOCAL_TIMESRCD_PID=$!
for h in "${ACTIVE_HOSTS[@]}"; do
  ssh_retry_bg "$h" "LD_LIBRARY_PATH=$REMOTE_ROOT/lib $REMOTE_ROOT/build/timesrcd/timesrcd --unlink --backend=$TIMESRC_BACKEND --ptp-dev=$TIMESRC_PTP_DEV > /tmp/timesrcd.log 2>&1" &
done
sleep "$(awk -v ms=$TIMESRC_WARMUP_MS 'BEGIN{print ms/1000}')"

stop_timesrcd() {
  kill "$LOCAL_TIMESRCD_PID" 2>/dev/null
  for h in "${ACTIVE_HOSTS[@]}"; do
    ssh_retry "$h" "pkill -9 -x $APP 2>/dev/null; pkill -TERM timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" &
  done
  wait
}
trap stop_timesrcd EXIT

echo "--- launching MPC parties ---"
PARTY_PIDS=()
for ((pid=N; pid>=1; pid--)); do
    host=${HOSTS[$pid]}
    ssh_retry_bg "$host" "$(tdma_env)LD_LIBRARY_PATH=$REMOTE_ROOT/lib $REMOTE_ROOT/build/benchmarks/$APP -p $pid --net-config $NET_CONFIG -b $B -s $S -n $N -r $REPEAT -t $THREADS 2>&1" > "$RESULTS/party${pid}.log" &
    PARTY_PIDS+=($!)
    sleep 0.3
done
sleep 1
env $(tdma_env) LD_LIBRARY_PATH="$LOCAL_ROOT/lib" \
    "$LOCAL_ROOT/build/benchmarks/$APP" \
    -p 0 --net-config "$NET_CONFIG" -b $B -s $S -n $N -r $REPEAT -t $THREADS_P0 \
    > "$RESULTS/party0.log" 2>&1 &
PARTY_PIDS+=($!)

wait "${PARTY_PIDS[@]}"

echo ""
echo "=== Per-party results ==="
for ((pid=0; pid<=N; pid++)); do
    host=${HOSTS[$pid]}
    [ -z "$host" ] && host="local"
    echo "--- Party $pid ($host) ---"
    grep -E "^pid:|^time:|^sent:" "$RESULTS/party${pid}.log" 2>/dev/null || echo "(no result lines)"
done
