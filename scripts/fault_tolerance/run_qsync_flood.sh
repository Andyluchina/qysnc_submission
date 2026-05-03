#!/bin/bash
# QSync-only FLOOD sweep over eno2 TSN.
# Sources: ds18 (192.168.1.14), ds13 (192.168.1.100). Each blasts UDP+SYN at all 3 targets.
set -u
N=3
D=100
GATES_LIST=(500000 1000000 1500000 2000000)
PER_RUN_TIMEOUT=${PER_RUN_TIMEOUT:-300}

LOCAL=/root/asterisk-native
REMOTE=/tmp/asterisk-native
NET=/tmp/asterisk_bundle/net_config_n3_tsn.json
HOSTS=(ds15 ds16 ds17)
TSN_TARGETS=(192.168.1.11 192.168.1.12 192.168.1.13)
FLOOD_SRC=(ds18)
FLOOD_PORT=10000
FLOOD_PPS=80000
FLOOD_PKT_SIZE=1400

OUT=/root/e1_sweep/results/motivation_v2/qsync_flood
mkdir -p "$OUT"
echo -e "rep\tn\tgates_total\tmax_t_ms\tthroughput_mul_s\tstatus" > "$OUT/summary.tsv"

cleanup_all() {
  for h in "${HOSTS[@]}" "${FLOOD_SRC[@]}"; do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
      "ps aux | grep -E 'asterisk|timesrcd|flood_blaster|nping' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9 2>/dev/null; rm -f /dev/shm/timesrc /dev/shm/timesrc-*; true" 2>/dev/null &
  done
  ps aux | grep -E "asterisk|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
  rm -f /dev/shm/timesrc /dev/shm/timesrc-*
  wait
  sleep 2
}

start_flood() {
  for src in "${FLOOD_SRC[@]}"; do
    for t in "${TSN_TARGETS[@]}"; do
      ssh -o ConnectTimeout=3 -o BatchMode=yes "$src" \
        "nohup python3 /tmp/flood_blaster.py $t $FLOOD_PORT $FLOOD_PKT_SIZE $FLOOD_PPS 600 > /tmp/flood_udp_${t}.log 2>&1 &
         nohup sudo nping --tcp --flags SYN -p $FLOOD_PORT --rate 50000 -c 30000000 -q $t > /tmp/flood_tcp_${t}.log 2>&1 &" >/dev/null 2>&1 &
    done
  done
  wait
  sleep 1
}

stop_flood() {
  for src in "${FLOOD_SRC[@]}"; do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$src" \
      "for pid in \$(pgrep -f 'flood_blaster|nping'); do sudo kill -9 \$pid; done; true" 2>/dev/null &
  done
  wait
}

for total_gates in "${GATES_LIST[@]}"; do
  G=$((total_gates / D))
  rdir="$OUT/run_${total_gates}"
  rm -rf "$rdir"; mkdir -p "$rdir"
  cleanup_all

  start_flood

  # Run QSync via run_native_tsn.sh (proven path)
  timeout $PER_RUN_TIMEOUT bash $LOCAL/run_native_tsn.sh $G $D 1 $N \
    > "$rdir/launcher.log" 2>&1
  for p in 0 1 2 3; do
    cp $LOCAL/results/party${p}.log "$rdir/p$p.log" 2>/dev/null || true
  done

  stop_flood

  # Require all 4 parties to report
  all_ok=1
  for p in 0 1 2 3; do
    if ! grep -q "^time:" "$rdir/p$p.log" 2>/dev/null; then all_ok=0; break; fi
  done
  if [ "$all_ok" = "1" ]; then
    maxt=$(for p in 0 1 2 3; do grep "^time:" "$rdir/p$p.log" | awk '{print $2}'; done | sort -n | tail -1)
    thr=$(awk -v t=$total_gates -v m=$maxt 'BEGIN{printf "%d", t*1000/m}')
    echo -e "1\t$N\t$total_gates\t$maxt\t$thr\tok" >> "$OUT/summary.tsv"
    breakdown=$(for p in 0 1 2 3; do
      v=$(grep "^time:" "$rdir/p$p.log" | awk '{print $2}')
      echo "P$p=${v:-?}"
    done | tr '\n' ' ')
    echo "RUN: proto=qsync gates=$total_gates row=flood status=ok max_t_ms=$maxt thr=$thr breakdown=[$breakdown]"
  else
    echo -e "1\t$N\t$total_gates\t0\t0\tfail" >> "$OUT/summary.tsv"
    nlines=$(for p in 0 1 2 3; do grep -c "^time:" "$rdir/p$p.log" 2>/dev/null || echo 0; done | paste -sd' ')
    echo "RUN: proto=qsync gates=$total_gates row=flood status=fail party_time_lines=[$nlines]"
  fi
done
echo "ALL_DONE qsync_flood"
