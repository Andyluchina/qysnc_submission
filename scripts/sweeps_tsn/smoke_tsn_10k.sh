#!/bin/bash
# TSN qsync smoke — n=3, hardware taprio on eno2, 10k gates (g=1000, d=10).
# Uses the no-accountability tree (asterisk-native_root, dbf9ad4 checkpoint).
# Assumes taprio is already installed on every eno2 host with matching schedule.
set -u
N=3
G=1000
D=10
PER_RUN_TIMEOUT=60

LOCAL=/root/qsync-ae/code
REMOTE=/tmp/asterisk-native_root
NETCFG_LOCAL=/root/qsync-ae/scripts/net_configs/net_config_n3_tsn.json
NETCFG_REMOTE=/tmp/qsync_ae_net_configs/net_config_n3_tsn.json
RDIR=/root/qsync-ae/results/smoke_tsn_10k
rm -rf "$RDIR"; mkdir -p "$RDIR"

ENO2_HOSTS=(server1 server2 server3)

# BcastBus + TDMA env (must match across all parties or pair-key derivation fails)
ENV="MPC_SO_PRIORITY=4 MPC_BROADCAST_IP=192.168.1.255 MPC_PAIR_KEY_SEED=200 MPC_NETWORK=tsn TDMA_SLOT_NS=1048544 TDMA_GUARD_NS=0"

# Clean stale procs
for h in "${ENO2_HOSTS[@]}"; do
  ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
    "ps aux | grep -E 'asterisk|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r kill -9 2>/dev/null; rm -f /dev/shm/timesrc /dev/shm/timesrc-*; true" &
done
ps aux | grep -E "asterisk|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
rm -f /dev/shm/timesrc /dev/shm/timesrc-*
wait

# timesrcds (PTP backend, /dev/ptp1)
"$LOCAL/build/timesrcd/timesrcd" --unlink --backend=ptp --ptp-dev=/dev/ptp1 \
    > "$RDIR/ts_local.log" 2>&1 &
LP=$!
for h in "${ENO2_HOSTS[@]}"; do
  ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
    "LD_LIBRARY_PATH=$REMOTE/lib timeout $PER_RUN_TIMEOUT $REMOTE/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1" \
    > "$RDIR/ts_$h.log" 2>&1 &
done
sleep 1.5

# MPC peers (P_N..P_1 remote, P_0 local)
for ((p=N; p>=1; p--)); do
  h=${ENO2_HOSTS[$((p-1))]}
  ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
    "$ENV LD_LIBRARY_PATH=$REMOTE/lib timeout $PER_RUN_TIMEOUT $REMOTE/build/benchmarks/asterisk_mpc -p $p --net-config $NETCFG_REMOTE -g $G -d $D -n $N -r 1 -t 6" \
    > "$RDIR/p$p.log" 2>&1 &
  sleep 0.3
done
sleep 1
env $ENV LD_LIBRARY_PATH="$LOCAL/lib" timeout $PER_RUN_TIMEOUT \
  "$LOCAL/build/benchmarks/asterisk_mpc" -p 0 --net-config $NETCFG_LOCAL -g $G -d $D -n $N -r 1 -t 6 \
  > "$RDIR/p0.log" 2>&1
RC=$?
echo "[$(date -Is)] P0 done (rc=$RC)"

# Wait for workers to finish (or up to PER_RUN_TIMEOUT seconds total)
for i in $(seq 1 $PER_RUN_TIMEOUT); do
  done_count=$(grep -lE "^time:" "$RDIR"/p*.log 2>/dev/null | wc -l)
  [ "$done_count" = "4" ] && break
  sleep 1
done

kill -9 $LP 2>/dev/null
for h in "${ENO2_HOSTS[@]}"; do
  ssh -o ConnectTimeout=2 -o BatchMode=yes "$h" \
    "ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r kill -9; true" 2>/dev/null &
done
wait

echo
echo "==== RESULTS (G=$G D=$D total=$((G*D)) n=$N) ===="
for p in 0 1 2 3; do
  t=$(grep -E "^time:" "$RDIR/p$p.log" | tail -1)
  s=$(grep -E "^sent:" "$RDIR/p$p.log" | tail -1)
  echo "P$p $t   $s"
done
echo
echo "==== TIMER lines ===="
grep -hE "^TIMER" "$RDIR"/p*.log | sort -u
echo
echo "==== TDMAScheduler stats ===="
grep -hE "TDMAScheduler" "$RDIR"/p*.log
echo
echo "==== BcastBus / NACK / retx (P0) ===="
grep -hE "BcastBus|tx\[|rx\[|tnacks|retx" "$RDIR/p0.log"
echo
echo "==== ANY ERRORS / TimeSource issues ===="
grep -hE "TimeSource|error|Error|abort|poison|TDMAScheduler: no TimeSource" "$RDIR"/p*.log | sort -u
echo
echo "Logs in: $RDIR"
exit $RC
