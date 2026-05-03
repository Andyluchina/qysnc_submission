#!/bin/bash
# QSync phase runner for Fig 3. BIN={asterisk_offline,asterisk_online}.
# Usage: BIN=asterisk_offline ./run_phase_qsync.sh <G> <D> <repeat> <n>
set -u
LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
NET=/tmp/asterisk_bundle/net_config_eno1.json
RES=$LOCAL/results
BIN=${BIN:-asterisk_offline}
G=${1:-500}; D=${2:-50}; REPEAT=${3:-1}; N=${4:-3}
THREADS=${THREADS:-6}
HOSTS=("" "ds15" "ds16" "ds17" "ds18" "ds13" "ds11")

ACTIVE=()
for ((p=1; p<=N; p++)); do ACTIVE+=("${HOSTS[$p]}"); done

ssh_retry_bg() { local host=$1; shift
  for i in 1 2 3 4 5 6 7 8; do
    timeout 600 ssh -o ConnectTimeout=4 -o BatchMode=yes "$host" "$@"
    rc=$?
    [ $rc -ne 255 ] && [ $rc -ne 124 ] && return $rc
    sleep 1
  done
  return 1
}

# Cleanup
for h in "${ACTIVE[@]}"; do
  ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "pkill -9 -x $BIN 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" &
done
wait
pkill -9 -x "$BIN" 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc
sleep 1

# timesrcd
"$LOCAL/build/timesrcd/timesrcd" --unlink --backend=fake \
    > "$RES/timesrcd_local.log" 2>&1 &
LP=$!
for h in "${ACTIVE[@]}"; do
  ssh_retry_bg "$h" "LD_LIBRARY_PATH=$REMOTE/lib $REMOTE/build/timesrcd/timesrcd --unlink --backend=fake > /tmp/timesrcd.log 2>&1" &
done
sleep 0.5

trap "kill $LP 2>/dev/null; for h in \"\${ACTIVE[@]}\"; do ssh -o ConnectTimeout=3 -o BatchMode=yes \"\$h\" 'pkill -9 -x $BIN; pkill -TERM timesrcd; rm -f /dev/shm/timesrc; true' & done; wait" EXIT

ENV="TDMA_DISABLED= TDMA_SLOT_NS=10000000 MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200"

PIDS=()
for ((pid=N; pid>=1; pid--)); do
  h=${HOSTS[$pid]}
  ssh_retry_bg "$h" "$ENV LD_LIBRARY_PATH=$REMOTE/lib $REMOTE/build/benchmarks/$BIN -p $pid --net-config $NET -g $G -d $D -n $N -r $REPEAT -t $THREADS 2>&1" > "$RES/party${pid}.log" &
  PIDS+=($!)
  sleep 0.3
done
sleep 1
env $ENV LD_LIBRARY_PATH="$LOCAL/lib" "$LOCAL/build/benchmarks/$BIN" \
  -p 0 --net-config "$NET" -g $G -d $D -n $N -r $REPEAT -t $THREADS \
  > "$RES/party0.log" 2>&1 &
PIDS+=($!)
wait "${PIDS[@]}"

echo "=== $BIN per-party result ==="
for ((pid=0; pid<=N; pid++)); do
  echo "P$pid: $(grep -E '^time:' $RES/party${pid}.log 2>/dev/null | tail -1)"
done
