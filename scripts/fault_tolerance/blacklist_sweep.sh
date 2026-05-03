#!/bin/bash
# Multi-rep blacklist time sweep for S3 (fake-NACK).
# Runs the Phase E smoke REPS times, extracts (^fault_start TAI) - (^onfault TAI)
# delta on each honest party, prints median.
set -u
REPS=${REPS:-5}
HOSTS=("ds26" "ds16" "ds17" "ds18")
TOTAL=${#HOSTS[@]}
N=3; G=2000; D=100; PER=60
LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
NETCONF=/tmp/asterisk_bundle/net_config_eno1_no_ds15.json
OUTDIR=${OUTDIR:-/tmp/blacklist_sweep}
mkdir -p $OUTDIR

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

ENVS_BASE="TDMA_DISABLED= TDMA_SLOT_NS=1048544 MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200 MPC_NETWORK=eno1 ACCOUNTABILITY_ENABLE=1 ACCOUNTABILITY_F=1 ACCOUNTABILITY_W=1000 ACCOUNTABILITY_TAU=4 ACCOUNTABILITY_Q=2 TDMA_RETX_K_SEND=1000 TDMA_RETX_K_RECV=1000"

> $OUTDIR/summary.txt

for r in $(seq 1 $REPS); do
  cleanup
  RDIR=$OUTDIR/rep$r; rm -rf $RDIR; mkdir -p $RDIR
  echo "[$(date -Is)] === rep $r ==="

  $LOCAL/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1 > $RDIR/ts.log 2>&1 &
  LP=$!
  for ((i=1; i<TOTAL; i++)); do
    ssh -o ConnectTimeout=4 -o BatchMode=yes "${HOSTS[$i]}" \
      "LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1" \
      > $RDIR/ts${HOSTS[$i]}.log 2>&1 &
  done
  sleep 1

  ssh -o ConnectTimeout=4 -o BatchMode=yes ds18 \
    "MPC_FAKE_NACK_VICTIM=1 $ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 3 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > $RDIR/p3.log 2>&1 &
  ssh -o ConnectTimeout=4 -o BatchMode=yes ds17 \
    "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 2 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > $RDIR/p2.log 2>&1 &
  sleep 0.2
  ssh -o ConnectTimeout=4 -o BatchMode=yes ds16 \
    "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 1 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
    > $RDIR/p1.log 2>&1 &
  sleep 0.5
  env $ENVS_BASE LD_LIBRARY_PATH=$LOCAL/lib timeout $PER \
    $LOCAL/build/benchmarks/asterisk_mpc -p 0 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6 \
    > $RDIR/p0.log 2>&1
  sleep 8
  kill -9 $LP 2>/dev/null
  cleanup

  # Extract fault_start (from p3) and per-party onfault.
  fault_start=$(grep "^\\^fault_start" $RDIR/p3.log | awk -F'tai_ns=' '{print $2}' | head -1)
  for p in 0 1 2; do
    onfault=$(grep "^\\^onfault" $RDIR/p$p.log | awk -F'tai_ns=' '{print $2}' | head -1)
    cross_round=$(grep "^\\^tau_cross" $RDIR/p$p.log | head -1 | awk -F'round=' '{print $2}' | awk '{print $1}')
    if [ -n "$fault_start" ] && [ -n "$onfault" ]; then
      delta_ns=$((onfault - fault_start))
      delta_ms=$(echo "scale=2; $delta_ns / 1000000" | bc)
      echo "rep=$r party=$p delta_ms=$delta_ms cross_round=$cross_round" | tee -a $OUTDIR/summary.txt
    else
      echo "rep=$r party=$p delta_ms=NA" | tee -a $OUTDIR/summary.txt
    fi
  done
done

echo
echo "=== summary ==="
cat $OUTDIR/summary.txt

# Median by party
echo
echo "=== median across reps ==="
for p in 0 1 2; do
  med=$(awk -v p=$p '$2=="party="p {gsub("delta_ms=", "", $3); if ($3 != "NA") print $3}' $OUTDIR/summary.txt | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) { print "NA"; exit }
      if (NR % 2) print a[(NR+1)/2]
      else print (a[NR/2] + a[NR/2+1]) / 2
    }')
  echo "  party=$p median_ms=$med"
done
