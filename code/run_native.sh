#!/bin/bash
# Run Asterisk MPC distributedly across up to 7 machines on eno1 (no TSN).
# Local (party 0):    /root/asterisk-native-non_tsn/
# Remote (1..6):      /tmp/asterisk-native-non_tsn/
#
# Party layout (eno1, public 1 GbE):
#   P0 = local         158.130.54.27
#   P1 = ds15          158.130.54.122
#   P2 = ds16          158.130.54.133
#   P3 = ds17          158.130.54.19
#   P4 = ds18          158.130.54.20
#   P5 = ds13          158.130.54.123  (added 2026-04-25, eno1 only)
#   P6 = ds11          158.130.54.124  (added 2026-04-25, eno1 only)
#
# `-n` here means number-of-compute-parties (matches existing code_host
# convention); n=6 → 6 compute parties + 1 dealer = 7 total.

set -u

LOCAL_ROOT=/root/asterisk-native-non_tsn
REMOTE_ROOT=/tmp/asterisk-native-non_tsn
NET_CONFIG=/tmp/asterisk_bundle/net_config_eno1.json

RESULTS=$LOCAL_ROOT/results
G=${1:-500}
D=${2:-50}
REPEAT=${3:-1}
N=${4:-6}                     # default n=6 → all 7 hosts; pass 3..6 to vary

# All seven hosts in order P0..P6. Index 0 is local (empty string).
HOSTS=("" "ds15" "ds16" "ds17" "ds18" "ds13" "ds11")

# Time source. Default 'fake' (CLOCK_REALTIME) since neither sync-TCP nor
# the no-TDMA UDP path needs sub-ms time. Set TIMESRC_BACKEND=ptp to use
# the eno1 PHC (/dev/ptp0); requires `start_ptp_eno1.sh` to be running.
TIMESRC_BACKEND=${TIMESRC_BACKEND:-fake}
TIMESRC_WARMUP_MS=${TIMESRC_WARMUP_MS:-500}
TIMESRC_PTP_DEV=${TIMESRC_PTP_DEV:-/dev/ptp0}    # eno1 PHC; /dev/ptp1 = TSN, do not use here

# TDMA scheduler. Off by default for the non_tsn directory — sync-TCP and
# plain-UDP runs don't need scheduling. To turn it ON for a run, pass
# `TDMA_DISABLED=` (empty) on the command line; setting TIMESRC_BACKEND=ptp
# first is recommended so slot boundaries are aligned across hosts.
#
# Note the `-` (not `:-`) in the default: an explicit empty value passed
# in by the caller turns TDMA on and is preserved as empty here. With the
# `:-` form, empty would silently fall back to the default of "1".
TDMA_DISABLED=${TDMA_DISABLED-1}
TDMA_SLOT_NS=${TDMA_SLOT_NS:-10000000}
TDMA_SCHEDULE=${TDMA_SCHEDULE:-}

# Retransmit layer (Stage 5 in RETRANSMIT_PLAN.md). Defaults match the
# UDPChannel built-in defaults; override on the command line for A/B
# benchmarking.
#   TDMA_RETX_K_SEND  : sender-side per-(peer, fragment) cap (default 5)
#   TDMA_RETX_K_RECV  : receiver-side per-fragment cap (default 5)
#   TDMA_RETX_DISABLED=1 : bypass the retx layer at runtime (no tx_buf_,
#                          no NACK drain, no inbound NACK handling).
#                          POISON arrival still aborts.
TDMA_RETX_K_SEND=${TDMA_RETX_K_SEND:-}
TDMA_RETX_K_RECV=${TDMA_RETX_K_RECV:-}
TDMA_RETX_DISABLED=${TDMA_RETX_DISABLED:-}

THREADS=${THREADS:-6}
THREADS_P0=${THREADS_P0:-$THREADS}

MEASURE_RSS=${MEASURE_RSS:-}
TIME_WRAPPER=""
[ -n "$MEASURE_RSS" ] && TIME_WRAPPER="/usr/bin/time -v"

tdma_env() {
  local out=""
  [ -n "$TDMA_DISABLED" ] && out+="TDMA_DISABLED=$TDMA_DISABLED "
  [ -n "$TDMA_SLOT_NS" ] && out+="TDMA_SLOT_NS=$TDMA_SLOT_NS "
  [ -n "$TDMA_SCHEDULE" ] && out+="TDMA_SCHEDULE=$TDMA_SCHEDULE "
  [ -n "$TDMA_RETX_K_SEND" ] && out+="TDMA_RETX_K_SEND=$TDMA_RETX_K_SEND "
  [ -n "$TDMA_RETX_K_RECV" ] && out+="TDMA_RETX_K_RECV=$TDMA_RETX_K_RECV "
  [ -n "$TDMA_RETX_DISABLED" ] && out+="TDMA_RETX_DISABLED=$TDMA_RETX_DISABLED "
  # BcastBus knobs — critical that these be consistent across all hosts,
  # otherwise different hosts route MPC traffic to different TC queues
  # under taprio and the protocol deadlocks.
  [ -n "${MPC_SO_PRIORITY-}" ] && out+="MPC_SO_PRIORITY=$MPC_SO_PRIORITY "
  [ -n "${MPC_BROADCAST_IP-}" ] && out+="MPC_BROADCAST_IP=$MPC_BROADCAST_IP "
  [ -n "${MPC_PAIR_KEY_SEED-}" ] && out+="MPC_PAIR_KEY_SEED=$MPC_PAIR_KEY_SEED "
  echo -n "$out"
}

mkdir -p "$RESULTS"

# Active hosts for this run: P1..PN. P0 is always local.
ACTIVE_HOSTS=()
for ((p=1; p<=N; p++)); do
  ACTIVE_HOSTS+=("${HOSTS[$p]}")
done

ssh_retry() {
  local host=$1; shift
  local i
  for i in 1 2 3 4 5 6 7 8; do
    timeout 8 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@" && return 0
    sleep 1
  done
  return 1
}
ssh_retry_bg() {
  local host=$1; shift
  local i
  for i in 1 2 3 4 5 6 7 8; do
    timeout 600 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@"
    local rc=$?
    if [ $rc -ne 255 ] && [ $rc -ne 124 ]; then return $rc; fi
    sleep 1
  done
  return 1
}

echo "=== Asterisk MPC (non-TSN, eno1) ==="
echo "n=$N g=$G d=$D repeat=$REPEAT timesrc=$TIMESRC_BACKEND tdma=$([ -n "$TDMA_DISABLED" ] && echo off || echo "slot=${TDMA_SLOT_NS}ns")"
echo "active hosts: P0=local, $(for ((p=1;p<=N;p++)); do echo -n "P$p=${HOSTS[$p]} "; done)"

# Stale state cleanup.
for h in "${ACTIVE_HOSTS[@]}"; do
  ssh_retry "$h" 'pkill -9 asterisk_mpc 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true' &
done
wait
pkill -9 asterisk_mpc 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc
sleep 1

# --- Phase 1: start timesrcd on every active machine ------------------------
echo "--- starting timesrcd (backend=$TIMESRC_BACKEND, ptp-dev=$TIMESRC_PTP_DEV) ---"
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
    ssh_retry "$h" 'pkill -TERM timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true' &
  done
  wait
}
trap stop_timesrcd EXIT

# --- Phase 2: launch MPC parties (highest pid first; party 0 last) ---------
echo "--- launching MPC parties ---"
PARTY_PIDS=()
for ((pid=N; pid>=1; pid--)); do
    host=${HOSTS[$pid]}
    ssh_retry_bg "$host" "$(tdma_env)LD_LIBRARY_PATH=$REMOTE_ROOT/lib $TIME_WRAPPER $REMOTE_ROOT/build/benchmarks/asterisk_mpc -p $pid --net-config $NET_CONFIG -g $G -d $D -n $N -r $REPEAT -t $THREADS 2>&1" > "$RESULTS/party${pid}.log" &
    PARTY_PIDS+=($!)
    sleep 0.3
done

sleep 1
env $(tdma_env) LD_LIBRARY_PATH="$LOCAL_ROOT/lib" $TIME_WRAPPER \
    "$LOCAL_ROOT/build/benchmarks/asterisk_mpc" \
    -p 0 --net-config "$NET_CONFIG" -g $G -d $D -n $N -r $REPEAT -t $THREADS_P0 \
    > "$RESULTS/party0.log" 2>&1 &
PARTY_PIDS+=($!)

wait "${PARTY_PIDS[@]}"

echo ""
echo "=== Per-party results ==="
for ((pid=0; pid<=N; pid++)); do
    host=${HOSTS[$pid]}
    [ -z "$host" ] && host="local"
    echo ""
    echo "--- Party $pid ($host) ---"
    grep -E "^pid:|^time:|^sent:" "$RESULTS/party${pid}.log" 2>/dev/null || echo "(no result lines — see $RESULTS/party${pid}.log)"
done
