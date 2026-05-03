#!/bin/bash
# Clean slot sweep: σ ∈ {1, 2, 5, 10}ms × G ∈ {1.0, 1.5, 2.0}M @ n=5 over eno1.
# - non_tsn binary (eno1 broadcast IP defaults to 255.255.255.255).
# - Per-run install eno1 taprio → SSH probe → run → drain → reset to mq.
# - Gate scheme: owner=0x1 (tc0/SSH only), non-owner=0x3 (tc0+tc1 — SSH always open).
# - backend=ptp /dev/ptp1 (TSN-disciplined PHC for cross-host time).
set -u

N=5
D=100
GATES_LIST=(1000000 1500000 2000000)
SLOT_MS_LIST=(1 2 5 10)
ENTRY_NS=262136
TOTAL_HOSTS=$((N+1))   # 6
ALL_HOSTS=("coord" "server1" "server2" "server3" "server4" "server5")

LOCAL=/root/asterisk-native_root
REMOTE=/tmp/asterisk-native_root
OUT=/root/e1_sweep/results/slot_sweep_clean
mkdir -p "$OUT"
echo -e "rep\tslot_ms\tslot_ns\tgates_total\tmax_t_ms\tthroughput_mul_s\tstatus" > "$OUT/summary.tsv"

# ---------- helpers ----------
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
  local slot_ns=$1
  local entries_per_owner=$(( (slot_ns + ENTRY_NS - 1) / ENTRY_NS ))
  local num_entries=$(( entries_per_owner * TOTAL_HOSTS ))
  local actual_slot_ns=$(( entries_per_owner * ENTRY_NS ))
  local cycle_ns=$(( num_entries * ENTRY_NS ))
  echo "  [taprio install] entries_per_owner=$entries_per_owner actual_slot=${actual_slot_ns}ns cycle=${cycle_ns}ns total_entries=$num_entries"
  for pid in $(seq 0 $((TOTAL_HOSTS-1))); do
    local h=${ALL_HOSTS[$pid]}
    local entries=""
    for s in $(seq 0 $((num_entries-1))); do
      local owner=$(( s / entries_per_owner ))
      if [ "$owner" = "$pid" ]; then
        entries+=" sched-entry S 0x1 ${ENTRY_NS}"
      else
        entries+=" sched-entry S 0x3 ${ENTRY_NS}"
      fi
    done
    local cmd="sudo tc qdisc replace dev eno1 parent root handle 100 taprio num_tc 2 map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 queues 1@0 1@1 base-time 1609731273000000000 $entries clockid CLOCK_TAI flags 0x0"
    if [ "$h" = "coord" ]; then bash -c "$cmd"; else ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" "$cmd"; fi
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
  echo "  [SSH PROBE OK] 5/5 remotes responsive after taprio install"
  return 0
}

# ---------- per-run ----------
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
      "$ENVS LD_LIBRARY_PATH=$REMOTE/lib timeout $timeout_s $REMOTE/build/benchmarks/asterisk_mpc -p $p --net-config /tmp/asterisk_bundle/net_config_eno1.json -g $G -d $D -n $N -r 1 -t 6" \
      > "$outdir/p$p.log" 2>&1 &
    sleep 0.2
  done
  sleep 0.5
  env $ENVS LD_LIBRARY_PATH=$LOCAL/lib timeout $timeout_s \
    $LOCAL/build/benchmarks/asterisk_mpc -p 0 --net-config /tmp/asterisk_bundle/net_config_eno1.json -g $G -d $D -n $N -r 1 -t 6 \
    > "$outdir/p0.log" 2>&1

  sleep 30   # let peers flush online phase (G=2M can lag P0 by 25s+)

  kill -9 $LP 2>/dev/null
  for ((i=1; i<TOTAL_HOSTS; i++)); do
    ssh -o ConnectTimeout=3 -o BatchMode=yes "${ALL_HOSTS[$i]}" \
      "ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r sudo kill -9; true" 2>/dev/null &
  done
  wait
  remove_taprio
  return 0
}

# ---------- main ----------
echo "[$(date -Is)] pre-sweep cleanup"
cleanup_all
echo "[$(date -Is)] starting sweep — 4 σ × 3 G = 12 runs"

for slot_ms in "${SLOT_MS_LIST[@]}"; do
  # Snap slot to multiples of ENTRY_NS=262136 (TSN hardware granularity).
  # σ=1ms → 4×262136 = 1.048544 ms (matches TSN switch slot exactly).
  # σ=2ms → 8×262136 = 2.097088 ms.  σ=5ms → 20×262136 = 5.242720 ms.  σ=10ms → 39×262136 = 10.223304 ms.
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
    10) timeout_s=480 ;;
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
    for p in 0 1 2 3 4 5; do
      if ! grep -q "^time:" "$rdir/p$p.log" 2>/dev/null; then all_ok=0; break; fi
    done
    if [ "$all_ok" = "1" ]; then
      maxt=$(for p in 0 1 2 3 4 5; do grep "^time:" "$rdir/p$p.log" | awk '{print $2}'; done | sort -n | tail -1)
      thr=$(awk -v t=$total_gates -v m=$maxt 'BEGIN{printf "%d", t*1000/m}')
      echo -e "1\t$slot_ms\t$slot_ns\t$total_gates\t$maxt\t$thr\tok" >> "$OUT/summary.tsv"
      echo "RUN: slot=${slot_ms}ms gates=$total_gates status=ok max_t_ms=$maxt thr=$thr"
    else
      missing=""
      for p in 0 1 2 3 4 5; do
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
