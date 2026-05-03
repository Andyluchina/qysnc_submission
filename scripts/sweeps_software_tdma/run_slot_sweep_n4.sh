#!/bin/bash
# n=4 slot sweep, ds15 excluded. REAL TDMA gate (own=0x3, others=0x1) — SSH still always
# allowed (tc0 set in EVERY entry: 0x3 has bit 0, 0x1 has bit 0).
# σ ∈ {1, 2, 5, 10} ms × G ∈ {1.0, 1.5, 2.0} M, ascending σ as requested.
# One-entry-per-slot taprio (avoids iproute2 1024B overflow at large σ).
set -u

N=4
D=100
GATES_LIST=(1000000 1500000 2000000)
SLOT_MS_LIST=(1 2 5 10)   # ascending
TOTAL_HOSTS=$((N+1))   # 5
ALL_HOSTS=("ds26" "ds16" "ds17" "ds18" "ds13")   # ds15 EXCLUDED — P0..P4

LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
NETCONF=/tmp/asterisk_bundle/net_config_eno1_no_ds15.json
OUT=/root/e1_sweep/results/slot_sweep_n4
mkdir -p "$OUT"
echo -e "rep\tslot_ms\tslot_ns\tgates_total\tmax_t_ms\tthroughput_mul_s\tstatus" > "$OUT/summary.tsv"

cleanup_all() {
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${ALL_HOSTS[$i]}" \
      "ps aux | grep -E 'asterisk|timesrcd|tcpdump' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9 2>/dev/null
       rm -f /dev/shm/timesrc /dev/shm/timesrc-*
       sudo tc qdisc replace dev eno1 root mq
       true" &
  done
  ps aux | grep -E "asterisk|timesrcd|tcpdump" | grep -v grep | awk '{print $2}' | xargs -r sudo kill -9 2>/dev/null
  rm -f /dev/shm/timesrc /dev/shm/timesrc-*
  sudo tc qdisc replace dev eno1 root mq
  wait
}

install_taprio() {
  # REAL TDMA: own slot = 0x3 (tc0+tc1 open — host CAN send MPC), other slots = 0x1 (only tc0/SSH).
  # tc0 is open in every entry (bit 0 set in both 0x3 and 0x1) — SSH never blocked.
  local SLOT_NS=$1
  echo "  [taprio install] one-entry-per-slot scheme: slot_ns=$SLOT_NS cycle_ns=$((SLOT_NS * TOTAL_HOSTS)) total_entries=$TOTAL_HOSTS"
  for pid in $(seq 0 $((TOTAL_HOSTS-1))); do
    local h=${ALL_HOSTS[$pid]}
    local entries=""
    for s in $(seq 0 $((TOTAL_HOSTS-1))); do
      if [ "$s" = "$pid" ]; then
        entries+=" sched-entry S 0x3 ${SLOT_NS}"   # own slot: tc0+tc1 open
      else
        entries+=" sched-entry S 0x1 ${SLOT_NS}"   # other slots: only tc0 (SSH) open
      fi
    done
    local cmd="sudo tc qdisc replace dev eno1 parent root handle 100 taprio num_tc 2 map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 queues 1@0 1@1 base-time 1609731273000000000 $entries clockid CLOCK_TAI flags 0x0"
    if [ "$h" = "ds26" ]; then bash -c "$cmd"; else ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" "$cmd"; fi
  done
}

remove_taprio() {
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${ALL_HOSTS[$i]}" "sudo tc qdisc replace dev eno1 root mq" &
  done
  sudo tc qdisc replace dev eno1 root mq
  wait
}

ssh_probe() {
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    local out=$(timeout 5 ssh -o ConnectTimeout=4 -o BatchMode=yes "${ALL_HOSTS[$i]}" "echo SSH_OK" 2>&1)
    if [ "$out" != "SSH_OK" ]; then
      echo "  [SSH PROBE FAIL] ${ALL_HOSTS[$i]}: $out"
      return 1
    fi
  done
  echo "  [SSH PROBE OK] $((TOTAL_HOSTS-1))/$((TOTAL_HOSTS-1)) remotes responsive"
  return 0
}

run_one() {
  local slot_ns=$1 G=$2 total_gates=$3 outdir=$4 timeout_s=$5
  cleanup_all
  install_taprio $slot_ns
  if ! ssh_probe; then
    remove_taprio
    return 1
  fi

  $LOCAL/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1 > "$outdir/ts.log" 2>&1 &
  local LP=$!
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    local h=${ALL_HOSTS[$i]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "LD_LIBRARY_PATH=$REMOTE/lib timeout $timeout_s $REMOTE/build/timesrcd/timesrcd --unlink --backend=ptp --ptp-dev=/dev/ptp1" \
      > "$outdir/ts$h.log" 2>&1 &
  done
  sleep 1

  local ENVS="TDMA_DISABLED= TDMA_SLOT_NS=$slot_ns MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200"
  for ((p=N; p>=1; p--)); do
    local h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "$ENVS LD_LIBRARY_PATH=$REMOTE/lib timeout $timeout_s $REMOTE/build/benchmarks/asterisk_mpc -p $p --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6" \
      > "$outdir/p$p.log" 2>&1 &
    sleep 0.2
  done
  sleep 0.5
  env $ENVS LD_LIBRARY_PATH=$LOCAL/lib timeout $timeout_s \
    $LOCAL/build/benchmarks/asterisk_mpc -p 0 --net-config $NETCONF -g $G -d $D -n $N -r 1 -t 6 \
    > "$outdir/p0.log" 2>&1
  sleep 30   # drain

  kill -9 $LP 2>/dev/null
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${ALL_HOSTS[$i]}" \
      "ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9; true" 2>/dev/null &
  done
  wait
  remove_taprio
  return 0
}

echo "[$(date -Is)] pre-sweep cleanup (n=4, ds15 excluded)"
cleanup_all

echo "[$(date -Is)] starting sweep — 4 σ × 3 G = 12 runs (REAL TDMA gate own=0x3 others=0x1)"

for slot_ms in "${SLOT_MS_LIST[@]}"; do
  case "$slot_ms" in
    1)  slot_ns=1048544 ;;
    2)  slot_ns=2097088 ;;
    5)  slot_ns=5242720 ;;
    10) slot_ns=10223304 ;;
  esac
  case "$slot_ms" in
    1)  timeout_s=240 ;;
    2)  timeout_s=240 ;;
    5)  timeout_s=360 ;;
    10) timeout_s=600 ;;
  esac

  for total_gates in "${GATES_LIST[@]}"; do
    G=$((total_gates / D))
    rdir="$OUT/slot${slot_ms}ms_g${total_gates}"
    rm -rf "$rdir"; mkdir -p "$rdir"
    echo
    echo "[$(date -Is)] >>> RUN slot=${slot_ms}ms (slot_ns=$slot_ns) gates=$total_gates timeout=${timeout_s}s"

    if ! run_one $slot_ns $G $total_gates "$rdir" $timeout_s; then
      echo -e "1\t$slot_ms\t$slot_ns\t$total_gates\t0\t0\tssh_blocked" >> "$OUT/summary.tsv"
      echo "RUN: slot=${slot_ms}ms gates=$total_gates status=ssh_blocked"
      continue
    fi

    all_ok=1
    for p in $(seq 0 $N); do
      if ! grep -q "^time:" "$rdir/p$p.log" 2>/dev/null; then all_ok=0; break; fi
    done
    if [ "$all_ok" = "1" ]; then
      maxt=$(for p in $(seq 0 $N); do grep "^time:" "$rdir/p$p.log" | awk '{print $2}'; done | sort -n | tail -1)
      thr=$(awk -v t=$total_gates -v m=$maxt 'BEGIN{printf "%d", t*1000/m}')
      echo -e "1\t$slot_ms\t$slot_ns\t$total_gates\t$maxt\t$thr\tok" >> "$OUT/summary.tsv"
      echo "RUN: slot=${slot_ms}ms gates=$total_gates status=ok max_t_ms=$maxt thr=$thr"
    else
      missing=""
      for p in $(seq 0 $N); do
        if ! grep -q "^time:" "$rdir/p$p.log" 2>/dev/null; then missing+="p$p "; fi
      done
      echo -e "1\t$slot_ms\t$slot_ns\t$total_gates\t0\t0\tfail" >> "$OUT/summary.tsv"
      echo "RUN: slot=${slot_ms}ms gates=$total_gates status=fail missing_time:=${missing% }"
    fi
  done
done

echo
echo "[$(date -Is)] ALL_DONE"
echo "=== summary.tsv ==="
cat "$OUT/summary.tsv"
