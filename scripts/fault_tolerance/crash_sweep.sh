#!/bin/bash
# S2 (crash fault) sweep at τ=20.
#
# Crash p3 mid-online; honest peers (p0, p1, p2) detect silence via
# liveness probe + emit one NACK per round about p3. NackLog dedupes
# to per-(issuer, p3, round). With ≥ f+1=2 honest issuers per round,
# SendBad fires; after τ rounds the Detector triggers Faulty(p3, 'S').
#
# Knobs tuned for fast crash detection:
#   ACCOUNTABILITY_PROBE_NS         = 6ms   (silence detection)
#   ACCOUNTABILITY_PROBE_INTERVAL_NS = 5.24ms (probe every TDMA cycle)
#   ACCOUNTABILITY_TAU              = 20
# Theoretical: silence(~6ms) + τ × cycle(5.24ms) + verdict(~1ms)
#   = 6 + 20×5.24 + 1 = ~112 ms.
set -u
REPS=${REPS:-5}
HOSTS=("coord" "server2" "server3" "server4")
TOTAL=${#HOSTS[@]}
N=3; G=2000; D=100; PER=60
T_FAULT=3
T_OBSERVE=10
LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
NETCONF=/tmp/asterisk_bundle/net_config_eno1_no_ds15.json
OUTDIR=${OUTDIR:-/tmp/crash_sweep_tau20}
mkdir -p "$OUTDIR"

cleanup() {
  for ((i=1; i<TOTAL; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${HOSTS[$i]}" "
      ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9 2>/dev/null
      rm -f /dev/shm/timesrc /dev/shm/timesrc-*
      true" &
  done
  ps aux | grep -E "asterisk_mpc|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r sudo kill -9 2>/dev/null
  rm -f /dev/shm/timesrc /dev/shm/timesrc-*
  wait
}

ENVS_BASE="TDMA_DISABLED= TDMA_SLOT_NS=1048544 MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200 MPC_NETWORK=eno1 ACCOUNTABILITY_ENABLE=1 ACCOUNTABILITY_F=1 ACCOUNTABILITY_W=30 ACCOUNTABILITY_TAU=20 ACCOUNTABILITY_TAU_R=1000000 ACCOUNTABILITY_SILENCE_TAU=20 ACCOUNTABILITY_Q=2 ACCOUNTABILITY_PROBE_NS=10000000 ACCOUNTABILITY_PROBE_INTERVAL_NS=5240000 TDMA_RETX_K_SEND=10000 TDMA_RETX_K_RECV=10000"

> "$OUTDIR/summary.txt"

for r in $(seq 1 $REPS); do
  cleanup
  RDIR="$OUTDIR/rep$r"; rm -rf "$RDIR"; mkdir -p "$RDIR"
  echo "[$(date -Is)] === rep $r ==="

  $LOCAL/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1 > "$RDIR/ts.log" 2>&1 &
  LP=$!
  for ((i=1; i<TOTAL; i++)); do
    ssh -o ConnectTimeout=4 -o BatchMode=yes "${HOSTS[$i]}" \
      "LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1" \
      > "$RDIR/ts${HOSTS[$i]}.log" 2>&1 &
  done
  sleep 1

  ssh -o ConnectTimeout=4 -o BatchMode=yes server4 \
    "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 3 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > "$RDIR/p3.log" 2>&1 &
  ssh -o ConnectTimeout=4 -o BatchMode=yes server3 \
    "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 2 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > "$RDIR/p2.log" 2>&1 &
  sleep 0.2
  ssh -o ConnectTimeout=4 -o BatchMode=yes server2 \
    "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 1 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > "$RDIR/p1.log" 2>&1 &
  sleep 0.5
  env $ENVS_BASE LD_LIBRARY_PATH=$LOCAL/lib timeout $PER \
    $LOCAL/build/benchmarks/asterisk_mpc -p 0 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6 \
    > "$RDIR/p0.log" 2>&1 &
  P0_PID=$!

  # Wait T_FAULT seconds, capture TAI clock, then crash p0 (dealer).
  # Dealer is the cleanest crash victim: sends constantly throughout
  # the protocol so silence is unambiguous (no natural silences from
  # protocol-phase quiescence).
  sleep $T_FAULT
  crash_tai_ns=$($LOCAL/build/timesrcd/timesrc_probe --samples=1 2>/dev/null \
    | grep "tag=probe idx=0" | awk -F't_shared_ns=' '{print $2}' \
    | awk '{print $1}')
  kill -9 $P0_PID 2>/dev/null
  echo "  crash_tai_ns=$crash_tai_ns (victim=p0 dealer)"
  echo "  crash_tai_ns=$crash_tai_ns" > "$RDIR/crash_tai.txt"

  # Observe.
  sleep $T_OBSERVE
  kill -9 $LP 2>/dev/null
  cleanup

  # Extract per-party onfault. Honest peers are p1, p2, p3 (p0 crashed).
  for p in 1 2 3; do
    onfault=$(grep "^\\^onfault" "$RDIR/p$p.log" | awk -F'tai_ns=' '{print $2}' | head -1)
    silence_event=$(grep "^\\^silence_fault" "$RDIR/p$p.log" | head -1)
    cross_round=$(grep "^\\^tau_cross\\|^\\^silence_fault" "$RDIR/p$p.log" | head -1 | awk -F'round=' '{print $2}' | awk '{print $1}')
    cross_kind=$(grep "^\\^tau_cross" "$RDIR/p$p.log" | head -1 | awk -F'kind=' '{print $2}' | awk '{print $1}')
    if [ -z "$cross_kind" ] && [ -n "$silence_event" ]; then cross_kind="silence"; fi
    if [ -n "$crash_tai_ns" ] && [ -n "$onfault" ]; then
      delta_ns=$((onfault - crash_tai_ns))
      delta_ms=$(echo "scale=2; $delta_ns / 1000000" | bc)
      echo "rep=$r party=$p delta_ms=$delta_ms cross_round=$cross_round cross_kind=$cross_kind" | tee -a "$OUTDIR/summary.txt"
    else
      echo "rep=$r party=$p delta_ms=NA cross_round=${cross_round:-NA}" | tee -a "$OUTDIR/summary.txt"
    fi
  done
done

echo
echo "=== summary ==="
cat "$OUTDIR/summary.txt"
echo
echo "=== median across reps ==="
for p in 1 2 3; do
  med=$(awk -v p=$p '$2=="party="p {gsub("delta_ms=", "", $3); if ($3 != "NA") print $3}' "$OUTDIR/summary.txt" | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) { print "NA"; exit }
      if (NR % 2) print a[(NR+1)/2]
      else print (a[NR/2] + a[NR/2+1]) / 2
    }')
  echo "  party=$p median_ms=$med"
done
