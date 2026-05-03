#!/bin/bash
# E1: throughput vs n. d=100, total gates = 1M (G=10000), n in {3,4,5,6}.
# All over eno1. Order:
#   1. sync   (asterisk_mpc on eno1 bare)
#   2. async  (dm_async_asterisk_online on eno1 bare; online phase only)
#   3. qsync  (asterisk_mpc on eno1 + kernel-taprio installed per-n)
set -u
G=10000
D=100
TOTAL_GATES=1000000
PER_RUN_TIMEOUT=${PER_RUN_TIMEOUT:-300}
PROTOS=${PROTOS:-"sync async qsync"}
N_VALUES=${N_VALUES:-"3 4 5 6"}

# Hosts in order: P0 = local, P1=server1, ..., P6=server6
ALL_HOSTS=("coord" "server1" "server2" "server3" "server4" "server5" "server6")

OUT=/root/e1_sweep/results/e1_n_sweep_eno1
mkdir -p $OUT/sync $OUT/qsync $OUT/async

cleanup() {
  local n=$1
  local total=$((n+1))
  for ((i=1; i<total; i++)); do
    h=${ALL_HOSTS[$i]}
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
      "ps aux | grep -E 'asterisk|timesrcd|dm_async' | grep -v grep | awk '{print \$2}' | xargs -r kill -9 2>/dev/null; rm -f /dev/shm/timesrc /dev/shm/timesrc-*; true" 2>/dev/null &
  done
  ps aux | grep -E "asterisk|dm_async|timesrcd" | grep -v grep | awk '{print $2}' | xargs -r kill -9 2>/dev/null
  rm -f /dev/shm/timesrc /dev/shm/timesrc-*
  wait
  sleep 2
}

active_hosts() {
  local n=$1
  local arr=("server1")
  for ((i=2; i<=n; i++)); do arr+=("${ALL_HOSTS[$i]}"); done
  echo "${arr[@]}"
}

# -------- sync (Asterisk full mpc) --------
run_sync() {
  local n=$1 outdir=$2
  cleanup $n
  for ((p=n; p>=1; p--)); do
    h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "LD_LIBRARY_PATH=/tmp/asterisk_bundle/lib timeout $PER_RUN_TIMEOUT /tmp/asterisk_bundle/asterisk_mpc -p $p --net-config /tmp/asterisk_bundle/net_config_n$n.json -g $G -d $D -n $n -r 1 -t 6" \
      > "$outdir/p$p.log" 2>&1 &
    sleep 0.3
  done
  sleep 1
  LD_LIBRARY_PATH=/tmp/asterisk_bundle/lib timeout $PER_RUN_TIMEOUT \
    /tmp/asterisk_bundle/asterisk_mpc -p 0 --net-config /tmp/asterisk_bundle/net_config_n$n.json -g $G -d $D -n $n -r 1 -t 64 \
    > "$outdir/p0.log" 2>&1
  wait
}

# -------- async DM online --------
run_async() {
  local n=$1 outdir=$2
  cleanup $n
  cp /root/e1_sweep/net_config_n$n.json /root/Asynchronous-HP-aided-MPC/net_config_n$n.json
  for ((p=n; p>=1; p--)); do
    h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "LD_LIBRARY_PATH=/root/Asynchronous-HP-aided-MPC/build/libs timeout $PER_RUN_TIMEOUT /root/Asynchronous-HP-aided-MPC/build/benchmarks/dm_async_asterisk_online -p $p --net-config /root/Asynchronous-HP-aided-MPC/net_config_n$n.json -g $G -d $D -n $n" \
      > "$outdir/p$p.log" 2>&1 &
    sleep 0.3
  done
  sleep 1
  LD_LIBRARY_PATH=/root/Asynchronous-HP-aided-MPC/build/libs timeout $PER_RUN_TIMEOUT \
    /root/Asynchronous-HP-aided-MPC/build/benchmarks/dm_async_asterisk_online -p 0 --net-config /root/Asynchronous-HP-aided-MPC/net_config_n$n.json -g $G -d $D -n $n -t 64 \
    > "$outdir/p0.log" 2>&1
  wait
}

# -------- qsync: install eno1 kernel-taprio (TSN-mimicking), then run --------
install_eno1_taprio() {
  local n=$1
  local total=$((n+1))
  # owner-slot pattern: gatemask 0x1 owner-slot, 0x2 others; map prio>=1 → tc1
  # Each host has 4 owner slots (262136 ns × 4 = 1.048ms), cycle = total × 4 × 262136 ns
  # Same as TSN config.
  local entries_per_owner=4
  local entry_ns=262136
  local num_entries=$((entries_per_owner * total))

  for pid in $(seq 0 $((total-1))); do
    local h=${ALL_HOSTS[$pid]}
    # Build entries for this pid as owner
    local entries=""
    for s in $(seq 0 $((num_entries-1))); do
      local owner=$((s / entries_per_owner))
      if [ "$owner" = "$pid" ]; then
        entries+=" sched-entry S 0x1 ${entry_ns}"
      else
        entries+=" sched-entry S 0x2 ${entry_ns}"
      fi
    done
    if [ "$h" = "coord" ]; then
      sudo tc qdisc replace dev eno1 parent root handle 100 taprio \
        num_tc 2 map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 \
        queues 1@0 1@1 \
        base-time 1609731273000000000 \
        $entries \
        clockid CLOCK_TAI flags 0x0 2>/dev/null
    else
      ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
        "sudo tc qdisc replace dev eno1 parent root handle 100 taprio num_tc 2 map 0 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 queues 1@0 1@1 base-time 1609731273000000000 $entries clockid CLOCK_TAI flags 0x0" 2>/dev/null
    fi
  done
}

remove_eno1_taprio() {
  local n=$1
  local total=$((n+1))
  for pid in $(seq 0 $((total-1))); do
    local h=${ALL_HOSTS[$pid]}
    if [ "$h" = "coord" ]; then
      sudo tc qdisc replace dev eno1 root mq 2>/dev/null
    else
      ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" "sudo tc qdisc replace dev eno1 root mq 2>/dev/null" &
    fi
  done
  wait
}

run_qsync() {
  local n=$1 outdir=$2
  cleanup $n
  install_eno1_taprio $n
  /root/asterisk-native_root/build/timesrcd/timesrcd --unlink --backend=fake \
    > "$outdir/ts.log" 2>&1 &
  local LP=$!
  for ((p=1; p<=n; p++)); do
    h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "LD_LIBRARY_PATH=/tmp/asterisk-native_root/lib timeout $PER_RUN_TIMEOUT /tmp/asterisk-native_root/build/timesrcd/timesrcd --unlink --backend=fake" > "$outdir/ts$h.log" 2>&1 &
  done
  sleep 1
  local ENVS="TDMA_DISABLED= TDMA_SLOT_NS=1048544 MPC_SO_PRIORITY=4 MPC_PAIR_KEY_SEED=200"
  for ((p=n; p>=1; p--)); do
    h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=4 -o BatchMode=yes "$h" \
      "$ENVS LD_LIBRARY_PATH=/tmp/asterisk-native_root/lib timeout $PER_RUN_TIMEOUT /tmp/asterisk-native_root/build/benchmarks/asterisk_mpc -p $p --net-config /tmp/asterisk_bundle/net_config_eno1.json -g $G -d $D -n $n -r 1 -t 6" \
      > "$outdir/p$p.log" 2>&1 &
    sleep 0.3
  done
  sleep 1
  env $ENVS LD_LIBRARY_PATH=/root/asterisk-native_root/lib \
    timeout $PER_RUN_TIMEOUT /root/asterisk-native_root/build/benchmarks/asterisk_mpc \
    -p 0 --net-config /tmp/asterisk_bundle/net_config_eno1.json -g $G -d $D -n $n -r 1 -t 6 \
    > "$outdir/p0.log" 2>&1
  # P0 has returned — kill timesrcds and any leftover ssh so wait completes fast.
  kill -9 $LP 2>/dev/null
  for ((p=1; p<=n; p++)); do
    h=${ALL_HOSTS[$p]}
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" \
      "ps aux | grep -E 'asterisk_mpc|timesrcd' | grep -v grep | awk '{print \$2}' | xargs -r kill -9; true" 2>/dev/null &
  done
  wait
  remove_eno1_taprio $n
}

extract_max() {
  local outdir=$1 n=$2
  for p in $(seq 0 $n); do
    if ! grep -q "^time:" "$outdir/p$p.log" 2>/dev/null; then return 0; fi
  done
  for p in $(seq 0 $n); do
    grep "^time:" "$outdir/p$p.log" | awk '{print $2}' | head -1
  done | sort -n | tail -1
}

emit() {
  local proto=$1 n=$2 maxt=$3 thr=$4 status=$5
  echo -e "1\t$n\t$TOTAL_GATES\t$maxt\t$thr\t$status" >> "$OUT/${proto}/summary.tsv"
}

# Reset summaries for the protocols we'll run
for proto in $PROTOS; do
  echo -e "rep\tn\tgates_total\tmax_t_ms\tthroughput_mul_s\tstatus" > "$OUT/${proto}/summary.tsv"
done

for proto in $PROTOS; do
  for n in $N_VALUES; do
    rdir="$OUT/${proto}/n${n}"
    rm -rf "$rdir"; mkdir -p "$rdir"
    case "$proto" in
      sync)  run_sync  $n "$rdir" ;;
      async) run_async $n "$rdir" ;;
      qsync) run_qsync $n "$rdir" ;;
    esac
    maxt=$(extract_max "$rdir" $n)
    if [ -n "$maxt" ]; then
      thr=$(awk -v t=$TOTAL_GATES -v m=$maxt 'BEGIN{printf "%d", t*1000/m}')
      emit "$proto" "$n" "$maxt" "$thr" ok
      echo "RUN: proto=$proto n=$n status=ok max_t_ms=$maxt thr=$thr"
    else
      emit "$proto" "$n" 0 0 fail
      echo "RUN: proto=$proto n=$n status=fail"
    fi
  done
done
echo "ALL_DONE protos=[$PROTOS] N=[$N_VALUES]"
