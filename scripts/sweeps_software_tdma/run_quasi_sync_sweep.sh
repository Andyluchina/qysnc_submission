#!/bin/bash
# Quasi-sync sweep: 1M gates (g=10000, d=100), n = 3..6 (compute parties),
# 10 ms TDMA slots, eno1 PTP backend, retx layer enabled.
#
# Saves per-party logs to /root/e1_sweep/results/quasi_sync/n<N>/ and
# emits per-run quasi_sync.json deltas which build_quasi_sync_summary.py
# rolls into a single e1_summary_quasi_sync.json.

set -u
LOCAL_ROOT=/root/asterisk-native_root
OUT=/root/e1_sweep/results/quasi_sync
mkdir -p "$OUT"

G=10000
D=100
TRIALS=1

for N in 3 4 5 6; do
  RUN_DIR="$OUT/n$N"
  mkdir -p "$RUN_DIR"
  echo ""
  echo "======================================================="
  echo "  quasi-sync n=$N (compute parties), g=$G d=$D"
  echo "======================================================="

  # Hard cleanup of any leftover state.
  pkill -9 -f asterisk_mpc 2>/dev/null || true
  for h in ds15 ds16 ds17 ds18 ds13 ds11; do
    ssh -o ConnectTimeout=3 "$h" "pkill -9 asterisk_mpc 2>/dev/null; true" 2>/dev/null &
  done
  wait || true
  sleep 2

  T0=$(date +%s%3N)
  TIMESRC_BACKEND=ptp TDMA_DISABLED= TDMA_SLOT_NS=10000000 \
    timeout 180 bash "$LOCAL_ROOT/run_native.sh" "$G" "$D" "$TRIALS" "$N" \
    > "$RUN_DIR/launcher.log" 2>&1
  RC=$?
  T1=$(date +%s%3N)
  WALL=$((T1-T0))
  echo "  rc=$RC wall=${WALL} ms"

  # Snapshot per-party logs.
  for pid in $(seq 0 $N); do
    cp "$LOCAL_ROOT/results/party${pid}.log" "$RUN_DIR/party${pid}.log" 2>/dev/null || true
  done

  # Quick health summary.
  echo "  per-party time / retx_sends:"
  for pid in $(seq 0 $N); do
    t=$(grep -m1 '^time:' "$RUN_DIR/party${pid}.log" 2>/dev/null | awk '{print $2}')
    s=$(grep -m1 '^sent:' "$RUN_DIR/party${pid}.log" 2>/dev/null | awk '{print $2}')
    retx=$(grep '^UDPChannel' "$RUN_DIR/party${pid}.log" 2>/dev/null | grep -oP 'retx_sends=\K[0-9]+' | awk '{a+=$1} END {print a+0}')
    pois=$(grep -c 'POISON' "$RUN_DIR/party${pid}.log" 2>/dev/null || echo 0)
    printf "    P%d  t=%-12s sent=%-12s retx=%-7s poison=%s\n" "$pid" "${t:-?}" "${s:-?}" "$retx" "$pois"
  done
done

echo ""
echo "Sweep complete. Build summary with build_quasi_sync_summary.py."
