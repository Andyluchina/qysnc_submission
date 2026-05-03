#!/bin/bash
# Apples-to-apples non-TSN: same kernel software taprio installed on eno1
# (4.194 ms cycle, 1 ms slot per host, 16x262136ns) — TDMA_DISABLED=1 so
# the kernel does the gating, exactly as TSN does on eno2.
set -u

OUT_BASE=/root/e1_sweep/results/n3_eno1_taprio_1ms
mkdir -p "$OUT_BASE"
SUMMARY="$OUT_BASE/summary.tsv"
printf "rep\tg\tgates_total\tn\tparties_complete\tmax_t_ms\tthroughput_mul_s\tretx_sends\tstatus\n" > "$SUMMARY"

REPS=3
GATES=(5000 10000 15000 20000)
N=3
QSYNC_LOCAL_ROOT=/root/asterisk-native_root

cleanup() {
  pkill -9 -f 'asterisk_mpc' 2>/dev/null || true
  for h in server1 server2 server3; do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" "pkill -9 -f asterisk_mpc 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" 2>/dev/null &
  done
  wait 2>/dev/null
  sleep 1
}

CFG_TOTAL=$((REPS * ${#GATES[@]}))
CFG_DONE=0
for rep in $(seq 1 $REPS); do
  for g in "${GATES[@]}"; do
    CFG_DONE=$((CFG_DONE+1))
    rdir="$OUT_BASE/rep${rep}_g${g}"
    rm -rf "$rdir"; mkdir -p "$rdir"
    cleanup
    echo ""
    echo "=== [$CFG_DONE/$CFG_TOTAL] non-TSN n=3 g=$g eno1 + KERNEL TAPRIO 1ms slot ==="
    T0=$(date +%s%3N)
    TIMESRC_BACKEND=ptp TDMA_DISABLED=1 \
      timeout 180 bash "$QSYNC_LOCAL_ROOT/run_native.sh" "$g" 100 1 "$N" \
      > "$rdir/launcher.log" 2>&1
    RC=$?
    T1=$(date +%s%3N); WALL=$((T1-T0))
    for pid in 0 1 2 3; do
      \cp -f "$QSYNC_LOCAL_ROOT/results/party${pid}.log" "$rdir/party${pid}.log" 2>/dev/null || true
    done
    maxt=$(grep -h '^time:' "$rdir"/party*.log 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
    n_ok=$(grep -l '^time:' "$rdir"/party*.log 2>/dev/null | wc -l)
    retx=$(grep -h 'retx_sends=' "$rdir"/party*.log 2>/dev/null | grep -oP 'retx_sends=\K[0-9]+' | awk '{a+=$1} END {print a+0}')
    if [ -n "${maxt:-}" ] && [ "${maxt:-0}" != "0" ]; then
      thr=$(awk -v g=$g -v d=100 -v t=$maxt 'BEGIN{printf "%d", g*d*1000/t}')
    else
      thr=0
    fi
    status=$([ "$RC" = "0" ] && [ "$n_ok" = "4" ] && echo "ok" || echo "rc=$RC,parties=$n_ok")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rep" "$g" "$((g*100))" "$N" "$n_ok" "${maxt:-0}" "$thr" "$retx" "$status" >> "$SUMMARY"
    echo "  rc=$RC wall=${WALL}ms parties=$n_ok/4 maxt=${maxt:-?}ms thr=$thr retx=$retx"
  done
done
echo "ALL DONE"
