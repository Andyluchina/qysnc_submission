#!/bin/bash
# Darkpool latency vs problem size on the TSN island.
#   apps:        Darkpool_CDA, Darkpool_VM
#   protocols:   sync TCP (eno1), qsync UDP+TDMA (eno2 + switch Qbv)
#   sizes (B=S): 16, 64, 256, 512, 1024
#   n=3 (TSN island has 4 hosts: P0 local + server1/16/17)
#   reps=5 (outer loop, so partial completion still gives full coverage)
# 100 runs total.
set -u

OUT_BASE=/root/e1_sweep/results/darkpool_size_sweep_tsn
mkdir -p "$OUT_BASE"
SUMMARY="$OUT_BASE/summary.tsv"
[ -s "$SUMMARY" ] || printf "rep\tapp\tprotocol\tB\tS\tn\tparties_complete\tmax_t_ms\tcircuit_depth\tcircuit_total\tstatus\n" > "$SUMMARY"

REPS=5
SIZES=(16 64 256 512 1024)
APPS=(Darkpool_CDA Darkpool_VM)
N=3
TSN_LOCAL_ROOT=/root/asterisk-native

cleanup() {
  for app in "${APPS[@]}"; do
    pkill -9 -x "$app" 2>/dev/null
  done
  pkill -9 timesrcd 2>/dev/null
  for h in server1 server2 server3; do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" "pkill -9 -x Darkpool_CDA; pkill -9 -x Darkpool_VM; pkill -9 timesrcd; rm -f /dev/shm/timesrc; true" 2>/dev/null &
  done
  wait || true
  sleep 2
}

extract_results() {
  local rdir=$1
  local maxt=$(grep -h '^time:' "$rdir"/party*.log 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  local n_ok=$(grep -l '^time:' "$rdir"/party*.log 2>/dev/null | wc -l)
  local depth=$(grep -h '^Depth:' "$rdir"/party*.log 2>/dev/null | head -1 | awk '{print $2}')
  local total=$(grep -h '^Total:' "$rdir"/party*.log 2>/dev/null | head -1 | awk '{print $2}')
  echo "${maxt:-0}|${n_ok}|${depth:-?}|${total:-?}"
}

CFG_TOTAL=$((REPS * ${#SIZES[@]} * ${#APPS[@]} * 2))
CFG_DONE=0
EXPECTED_PARTIES=$((N+1))

for REP in $(seq 1 $REPS); do
  for APP in "${APPS[@]}"; do
    for B in "${SIZES[@]}"; do
      S=$B
      # ---- sync TCP ----
      CFG_DONE=$((CFG_DONE+1))
      RDIR="$OUT_BASE/rep${REP}_sync_${APP}_B${B}"
      rm -rf "$RDIR"; mkdir -p "$RDIR"
      cleanup
      echo ""
      echo "=== [$CFG_DONE/$CFG_TOTAL] rep=$REP sync TCP $APP B=S=$B n=$N ==="
      T0=$(date +%s%3N)
      timeout 240 bash /root/e1_sweep/run_darkpool_distributed_tsn.sh "$APP" "$B" "$S" 1 "$RDIR" \
        > "$RDIR/launcher.log" 2>&1
      RC=$?
      T1=$(date +%s%3N); WALL=$((T1-T0))
      IFS='|' read -r maxt n_ok depth total <<< "$(extract_results "$RDIR")"
      status=$([ "$RC" = "0" ] && [ "$n_ok" = "$EXPECTED_PARTIES" ] && echo "ok" || echo "rc=$RC,parties=$n_ok")
      printf "%s\t%s\tsync\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$REP" "$APP" "$B" "$S" "$N" "$n_ok" "$maxt" "$depth" "$total" "$status" >> "$SUMMARY"
      echo "  rc=$RC wall=${WALL}ms parties=$n_ok/$EXPECTED_PARTIES maxt=${maxt}ms depth=$depth gates=$total status=$status"

      # ---- qsync (TSN) ----
      CFG_DONE=$((CFG_DONE+1))
      RDIR="$OUT_BASE/rep${REP}_qsync_${APP}_B${B}"
      rm -rf "$RDIR"; mkdir -p "$RDIR"
      cleanup
      echo ""
      echo "=== [$CFG_DONE/$CFG_TOTAL] rep=$REP qsync(TSN) $APP B=S=$B n=$N ==="
      T0=$(date +%s%3N)
      APP="$APP" timeout 240 bash /root/e1_sweep/run_darkpool_tsn.sh "$B" "$S" 1 "$RDIR" \
        > "$RDIR/launcher.log" 2>&1
      RC=$?
      T1=$(date +%s%3N); WALL=$((T1-T0))
      IFS='|' read -r maxt n_ok depth total <<< "$(extract_results "$RDIR")"
      status=$([ "$RC" = "0" ] && [ "$n_ok" = "$EXPECTED_PARTIES" ] && echo "ok" || echo "rc=$RC,parties=$n_ok")
      printf "%s\t%s\tqsync\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$REP" "$APP" "$B" "$S" "$N" "$n_ok" "$maxt" "$depth" "$total" "$status" >> "$SUMMARY"
      echo "  rc=$RC wall=${WALL}ms parties=$n_ok/$EXPECTED_PARTIES maxt=${maxt}ms depth=$depth gates=$total status=$status"
    done
  done
  echo "--- rep $REP/$REPS done ---"
done
echo "ALL DONE"
