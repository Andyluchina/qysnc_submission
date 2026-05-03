#!/bin/bash
# Phase F (Scenario 2) smoke: crash p3 at T_fault sec into the run.
# Measure time from kill to OnFault fire on honest peers.
# Protocol will hang post-crash (no alive_mask integration); we kill it
# all after T_observe.
set -u
N=3
HOSTS=("coord" "server2" "server3" "server4")
TOTAL=${#HOSTS[@]}
G=10000; D=100; PER=180       # 1M gates → online ~40s, dealer ~10-15s
T_FAULT=20     # crash mid-online (after offline + dealer done)
T_OBSERVE=25   # need probe_timeout + slack
LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
NETCONF=/tmp/asterisk_bundle/net_config_eno1_no_ds15.json
RDIR=/tmp/smoke_phase_f_crash; rm -rf $RDIR; mkdir -p $RDIR

cleanup() {
  for ((i=1; i<TOTAL; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${HOSTS[$i]}" "
      ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -TERM 2>/dev/null
      sleep 1
      ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9 2>/dev/null
      rm -f /dev/shm/timesrc /dev/shm/timesrc-*
      true" &
  done
  ps aux | grep -E "asterisk_mpc|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r sudo kill -TERM 2>/dev/null
  sleep 1
  ps aux | grep -E "asterisk_mpc|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r sudo kill -9 2>/dev/null
  rm -f /dev/shm/timesrc /dev/shm/timesrc-*
  wait
}

cleanup
echo "[$(date -Is)] === Phase F crash smoke (n=$N, victim=p3 server4) ==="

$LOCAL/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1 > $RDIR/ts.log 2>&1 &
LP=$!
for ((i=1; i<TOTAL; i++)); do
  ssh -o ConnectTimeout=4 -o BatchMode=yes "${HOSTS[$i]}" \
    "LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1" \
    > $RDIR/ts${HOSTS[$i]}.log 2>&1 &
done
sleep 1

ENVS_BASE="TDMA_DISABLED= TDMA_SLOT_NS=1048544 MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200 MPC_NETWORK=eno1 ACCOUNTABILITY_ENABLE=1 ACCOUNTABILITY_F=1 ACCOUNTABILITY_W=1000 ACCOUNTABILITY_TAU=4 ACCOUNTABILITY_Q=2 ACCOUNTABILITY_DUMP=1 ACCOUNTABILITY_PROBE_NS=10000000000 TDMA_RETX_K_SEND=1000 TDMA_RETX_K_RECV=1000"

# Use the small G; protocol enters online phase quickly so crash hits there.
G_BIG=$G
ssh -o ConnectTimeout=4 -o BatchMode=yes server4 \
  "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 3 --net-config $NETCONF -g $G_BIG -d $D -n $N -r 1 -t 6" \
  > $RDIR/p3.log 2>&1 &
ssh -o ConnectTimeout=4 -o BatchMode=yes server3 \
  "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 2 --net-config $NETCONF -g $G_BIG -d $D -n $N -r 1 -t 6" \
  > $RDIR/p2.log 2>&1 &
sleep 0.2
ssh -o ConnectTimeout=4 -o BatchMode=yes server2 \
  "$ENVS_BASE LD_LIBRARY_PATH=$REMOTE/lib timeout $PER $REMOTE/build/benchmarks/asterisk_mpc -p 1 --net-config $NETCONF -g $G_BIG -d $D -n $N -r 1 -t 6" \
  > $RDIR/p1.log 2>&1 &
sleep 0.5
env $ENVS_BASE LD_LIBRARY_PATH=$LOCAL/lib timeout $PER \
  $LOCAL/build/benchmarks/asterisk_mpc -p 0 --net-config $NETCONF -g $G_BIG -d $D -n $N -r 1 -t 6 \
  > $RDIR/p0.log 2>&1 &
P0_PID=$!

# Wait T_FAULT seconds, then crash p3
sleep $T_FAULT
echo "[$(date -Is)] === CRASH inject: kill -9 asterisk_mpc on server4 ==="
# Capture TAI from PTP-synced timesrc shm BEFORE issuing the kill.
crash_tai_ns=$($LOCAL/build/timesrcd/timesrc_probe --samples=1 2>/dev/null \
  | grep "tag=probe idx=0" | awk -F't_shared_ns=' '{print $2}' \
  | awk '{print $1}')
ssh -o ConnectTimeout=3 -o BatchMode=yes server4 \
  "ps aux | grep asterisk_mpc | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9"
echo "  crash_tai_ns=$crash_tai_ns"

# Observe for T_OBSERVE more seconds
sleep $T_OBSERVE

# Kill everything
kill -9 $P0_PID 2>/dev/null
kill -9 $LP 2>/dev/null
cleanup

echo
echo "=== fault_start (kill timestamp from local clock, NOT TAI-aligned) ==="
echo "  local_ns=$crash_tai_ns"
echo
echo "=== ^onfault TAI events ==="
grep -E "^\^onfault:" $RDIR/p*.log
echo
echo "=== Faulty events ==="
grep -E "Arbiter\[|local Faulty|FIRED" $RDIR/p*.log | head -20
echo
echo "=== protocol completion (will be missing for hung parties) ==="
grep "^time:" $RDIR/p*.log
echo
echo "=== NackLog observed ==="
grep -E "NackLog\[p=" $RDIR/p*.log
