#!/bin/bash
# Sweep MPC gate count vs flood condition, post-CIR-cap config.
# Switch state required: alt-mask Qbv on GE1/0/5..8 + CIR 64 kbps on GE1/0/4.
# Host taprio: 4.194 ms cycle on each MPC host.
#
# Workload axis: g ∈ {5000, 10000, 15000, 20000}, d=100 → 0.5M..2M gates
# Condition axis: no-flood, under-flood (ds18 → P0 line-rate)
# Reps: 3 per cell.
set -u

OUT_BASE=/root/asterisk-native/results/flood_sweep
mkdir -p "$OUT_BASE"
SUMMARY="$OUT_BASE/summary.tsv"
[ -s "$SUMMARY" ] || printf "rep\tcondition\tg\tgates_total\tn\tparties_complete\tmax_t_ms\tthroughput_mul_s\tretx_sends\tstatus\n" > "$SUMMARY"

REPS=3
GATES=(5000 10000 15000 20000)
N=3
ANCHOR=1609731273000000000

start_sink() {
  nohup python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8*1024*1024)
s.bind(('192.168.1.10', 19999))
buf = bytearray(4096)
while True:
    try: s.recvfrom_into(buf)
    except: pass
" >/dev/null 2>&1 &
  echo $!
}

start_flood() {
  ssh -o BatchMode=yes -f ds18 "nohup python3 /tmp/flood_one.py 192.168.1.10 180 16 > /tmp/sweep_flood.out 2>&1 < /dev/null"
}

stop_flood() {
  ssh -o BatchMode=yes ds18 "pkill -9 -f flood_one 2>/dev/null; true" 2>/dev/null
}

cleanup_mpc() {
  pkill -9 -x asterisk_mpc 2>/dev/null
  for h in ds15 ds16 ds17; do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" "pkill -9 -x asterisk_mpc 2>/dev/null; pkill -9 timesrcd 2>/dev/null; rm -f /dev/shm/timesrc; true" &
  done
  wait || true; sleep 1
}

run_one() {
  local rep=$1; local cond=$2; local g=$3
  local gates_total=$((g * 100))
  local rdir="$OUT_BASE/rep${rep}_${cond}_g${g}"
  rm -rf "$rdir"; mkdir -p "$rdir"
  cleanup_mpc
  echo ""
  echo "=== rep $rep | $cond | g=$g (${gates_total} gates) ==="
  T0=$(date +%s%3N)
  TDMA_DISABLED=1 TIMESRC_BACKEND=ptp TIMESRC_PTP_DEV=/dev/ptp1 \
    timeout 120 bash /root/asterisk-native/run_native_tsn.sh "$g" 100 1 "$N" \
    > "$rdir/launcher.log" 2>&1
  RC=$?
  T1=$(date +%s%3N); WALL=$((T1-T0))
  for pid in 0 1 2 3; do
    \cp -f /root/asterisk-native/results/party${pid}.log "$rdir/party${pid}.log" 2>/dev/null || true
  done
  local maxt=$(grep -h '^time:' "$rdir"/party*.log 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  local n_ok=$(grep -l '^time:' "$rdir"/party*.log 2>/dev/null | wc -l)
  local retx=$(grep -h 'retx_sends=' "$rdir"/party*.log 2>/dev/null | grep -oP 'retx_sends=\K[0-9]+' | awk '{a+=$1} END {print a+0}')
  local thr=0
  if [ -n "${maxt:-}" ] && [ "$maxt" != "0" ]; then
    thr=$(awk -v g=$g -v d=100 -v t=$maxt 'BEGIN{printf "%d", g*d*1000/t}')
  fi
  local status=$([ "$RC" = "0" ] && [ "$n_ok" = "4" ] && echo "ok" || echo "rc=$RC,parties=$n_ok")
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rep" "$cond" "$g" "$gates_total" "$N" "$n_ok" "${maxt:-0}" "$thr" "$retx" "$status" >> "$SUMMARY"
  echo "  rc=$RC wall=${WALL}ms parties=$n_ok/4 maxt=${maxt:-?}ms thr=$thr retx=$retx status=$status"
}

CFG_TOTAL=$((REPS * ${#GATES[@]} * 2))
CFG_DONE=0
for rep in $(seq 1 $REPS); do
  for g in "${GATES[@]}"; do
    # no-flood
    CFG_DONE=$((CFG_DONE+1))
    echo ""
    echo "###### [$CFG_DONE/$CFG_TOTAL] no-flood ######"
    stop_flood
    run_one "$rep" "noflood" "$g"
    sleep 1

    # under-flood
    CFG_DONE=$((CFG_DONE+1))
    echo ""
    echo "###### [$CFG_DONE/$CFG_TOTAL] under-flood ######"
    SINK_PID=$(start_sink); sleep 1
    start_flood; sleep 5
    run_one "$rep" "flood" "$g"
    stop_flood; kill $SINK_PID 2>/dev/null
    sleep 1
  done
done
echo ""
echo "=== summary ==="
column -t "$SUMMARY"
echo "ALL DONE"
