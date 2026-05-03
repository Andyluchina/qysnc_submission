#!/bin/bash
# qsync-only sweep on TSN island. Both apps × 5 sizes × 1 rep × N reps.
# Uses asterisk-native_root binary on TSN island via run_darkpool_tsn.sh.
# Per-cell per-party emit appended to per_party.tsv.
#
#   Usage: REPS=3 OUT_BASE=/path ./run_qsync_only_sweep.sh
set -u

OUT_BASE=${OUT_BASE:-/root/e1_sweep/results/qsync_only_$(date +%H%M)}
mkdir -p "$OUT_BASE"
SUMMARY="$OUT_BASE/summary.tsv"
PERPARTY="$OUT_BASE/per_party.tsv"
[ -s "$SUMMARY" ]  || printf "rep\tapp\tB\tS\tn\tparties_complete\tmax_t_ms\tcircuit_depth\tcircuit_total\twall_ms\tstatus\n" > "$SUMMARY"
[ -s "$PERPARTY" ] || printf "rep\tapp\tB\tn\tparty\ttime_ms\tbytes_sent\tdepth\ttotal_gates\tstatus\n" > "$PERPARTY"

REPS=${REPS:-1}
SIZES=(16 64 256 512 1024)
APPS=(Darkpool_CDA Darkpool_VM)
N=3
EXPECTED_PARTIES=$((N+1))

cleanup() {
  for app in "${APPS[@]}"; do pkill -9 -x "$app" 2>/dev/null; done
  pkill -9 timesrcd 2>/dev/null
  for h in server1 server2 server3; do
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" "pkill -9 -x Darkpool_CDA; pkill -9 -x Darkpool_VM; pkill -9 timesrcd; rm -f /dev/shm/timesrc; true" 2>/dev/null &
  done
  wait || true
  sleep 2
}

extract_per_party() {
  local rdir=$1
  local n_ok=0 maxt=0 depth="?" total="?"
  for pid in 0 1 2 3; do
    local f="$rdir/party${pid}.log"
    local t=$(grep -E '^time:' "$f" 2>/dev/null | tail -1 | awk '{print $2}')
    if [ -n "$t" ]; then
      n_ok=$((n_ok+1))
      awk -v a="$t" -v b="$maxt" 'BEGIN{exit !(a+0 > b+0)}' && maxt=$t
    fi
    if [ "$depth" = "?" ]; then
      local d=$(grep -E '^Depth:' "$f" 2>/dev/null | head -1 | awk '{print $2}')
      [ -n "$d" ] && depth=$d
    fi
    if [ "$total" = "?" ]; then
      local g=$(grep -E '^Total:' "$f" 2>/dev/null | head -1 | awk '{print $2}')
      [ -n "$g" ] && total=$g
    fi
  done
  echo "${n_ok}|${maxt}|${depth}|${total}"
}

emit_per_party_rows() {
  local rep=$1 app=$2 B=$3 rdir=$4 depth=$5 total=$6
  for pid in 0 1 2 3; do
    local f="$rdir/party${pid}.log"
    local t=$(grep -E '^time:' "$f" 2>/dev/null | tail -1 | awk '{print $2}')
    local b=$(grep -E '^sent:' "$f" 2>/dev/null | tail -1 | awk '{print $2}')
    local status="ok"
    if [ -z "$t" ]; then status="missing"; t=""; fi
    [ -z "$b" ] && b=""
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rep" "$app" "$B" "$N" "$pid" "$t" "$b" "$depth" "$total" "$status" >> "$PERPARTY"
  done
}

CFG_TOTAL=$((REPS * ${#SIZES[@]} * ${#APPS[@]}))
CFG_DONE=0

for REP in $(seq 1 $REPS); do
  for APP in "${APPS[@]}"; do
    for B in "${SIZES[@]}"; do
      S=$B
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
      RES=$(extract_per_party "$RDIR")
      n_ok=$(echo "$RES" | awk -F'|' '{print $1}')
      maxt=$(echo "$RES" | awk -F'|' '{print $2}')
      depth=$(echo "$RES" | awk -F'|' '{print $3}')
      total=$(echo "$RES" | awk -F'|' '{print $4}')
      status=$([ "$RC" = "0" ] && [ "$n_ok" = "$EXPECTED_PARTIES" ] && echo "ok" || echo "rc=$RC,parties=$n_ok")
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$REP" "$APP" "$B" "$S" "$N" "$n_ok" "$maxt" "$depth" "$total" "$WALL" "$status" >> "$SUMMARY"
      emit_per_party_rows "$REP" "$APP" "$B" "$RDIR" "$depth" "$total"
      echo "  rc=$RC wall=${WALL}ms parties=$n_ok/$EXPECTED_PARTIES maxt=${maxt}ms depth=$depth gates=$total status=$status"
      for pid in 0 1 2 3; do
        t=$(grep -E '^time:' "$RDIR/party${pid}.log" 2>/dev/null | tail -1 | awk '{print $2}')
        b=$(grep -E '^sent:' "$RDIR/party${pid}.log" 2>/dev/null | tail -1 | awk '{print $2}')
        echo "    P$pid: time=${t:-MISSING}ms sent=${b:-?}B"
      done
    done
  done
done
echo ""
echo "ALL DONE — summary at $SUMMARY"
