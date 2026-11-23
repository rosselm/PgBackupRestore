#!/usr/bin/env bash
# Measures what summarize_wal costs at promotion time.
#
# For each combination of  summarize_wal = on|off  and  load = idle|pgbench  it performs N planned
# switchovers and records, per promotion:
#   promote_s              PostgreSQL log: "received promote request" -> "ready to accept connections"
#   waited_for_summarizer  1 if the log shows "still waiting for WAL summarization" (>= 10 s wait)
#   summarizer_lag_bytes   replay LSN minus summarized LSN on the candidate just before the switchover
#   s_since_restartpoint   age of the candidate's last restartpoint just before the switchover
#   client_write_gap_s     longest gap between two heartbeat rows around the switchover: the write
#                          outage an application sees (includes Patroni's own part of a switchover)
#
#   N=6 OUT=docs/promotion-measurements.csv tests/measure-promotion.sh
#
# Leaves the cluster as it found it (summarize_wal = on, no load, bench database dropped).
source "$(dirname "$0")/lib.sh"
N=${N:-6}
OUT=${OUT:-$TESTS_DIR/../docs/promotion-measurements.csv}
BENCH_ENV="PGHOST=$(tr ' ' ',' <<<"$PG_NODES") PGUSER=postgres PGPASSWORD=$PG_SUPERUSER_PASSWORD PGTARGETSESSIONATTRS=read-write PGCONNECT_TIMEOUT=2"

writable() { [[ "$(nsql "$1" postgres "select pg_is_in_recovery()" 2>/dev/null || true)" == f ]]; }
wait_writable() { local i; for i in $(seq 1 180); do writable "$1" && return 0; sleep 1; done; return 1; }

set_summarize() { # on|off, applied cluster-wide through Patroni (reload, no restart)
  ctl edit-config -s "postgresql.parameters.summarize_wal=$1" --force >/dev/null
  local i n ok
  for i in $(seq 1 60); do
    ok=1
    for n in $PG_NODES; do [[ "$(nsql "$n" postgres "show summarize_wal" 2>/dev/null || true)" == "$1" ]] || ok=0; done
    (( ok )) && return 0
    sleep 2
  done
  echo "summarize_wal=$1 was not applied everywhere" >&2; return 1
}

stop_load() { orb -m "$BACKUP_HOST" sudo systemctl stop pglab-bench >/dev/null 2>&1 || true; }
start_load() {
  wait_writable "$(leader)"
  nsql "$(leader)" postgres "select 1 from pg_database where datname = 'bench'" | grep -q 1 \
    || nsql "$(leader)" postgres "create database bench"
  bsh "env $BENCH_ENV $PGBIN/pgbench -i -q -s 5 bench" >/dev/null 2>&1
  stop_load
  orb -m "$BACKUP_HOST" sudo systemd-run --quiet --unit pglab-bench --uid postgres \
    /bin/bash -c "while true; do env $BENCH_ENV $PGBIN/pgbench -n -c 4 -j 2 -R 200 -T 3600 bench >/dev/null 2>&1; sleep 1; done"
  sleep 20   # let it produce WAL before the first measurement
}

cleanup() {
  stop_load
  set_summarize on || true
  wait_writable "$(leader)" && nsql "$(leader)" postgres "drop database if exists bench" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cycle() { # mode load run
  local mode=$1 load=$2 run=$3 L C lag since t0 p tli gap
  L=$(leader); C=$(replicas | head -1)
  wait_replicas 2
  sleep $(( 5 + RANDOM % 30 ))        # vary how long ago the candidate's last restartpoint was
  lag=NA
  [[ $mode == on ]] && lag=$(nsql "$C" postgres "select coalesce(pg_wal_lsn_diff(pg_last_wal_replay_lsn(), summarized_lsn)::bigint::text, 'NA') from pg_get_wal_summarizer_state()")
  since=$(nsql "$C" postgres "select round(extract(epoch from now() - checkpoint_time)) from pg_control_checkpoint()")
  t0=$(orb -m "$C" date +%s)
  ctl switchover --leader "$L" --candidate "$C" --force >/dev/null
  wait_writable "$C" || { echo "$C never became writable" >&2; return 1; }
  # promotion duration and summarizer wait, from the PostgreSQL log of the promoted node
  local i
  for i in 1 2 3 4 5; do
    p=$(orb -m "$C" sudo journalctl -u patroni --since "@$t0" -o short-unix --no-pager | awk '
        /received promote request/ && !p { p = $1 }
        /database system is ready to accept connections/ && p && !r { r = $1 }
        /still waiting for WAL summarization/ { w = 1 }
        END { if (p && r) printf "%.1f,%d", r - p, w + 0 }')
    [[ -n $p ]] && break
    sleep 2
  done
  wait_replicas 2
  sleep 5                             # a few heartbeats after the gap
  gap=$(nsql "$C" demo "select round(extract(epoch from max(g))::numeric, 1) from (select ts - lag(ts) over (order by ts) as g from heartbeat where ts > to_timestamp($t0) - interval '5 seconds') s")
  tli=$(nsql "$C" postgres "select timeline_id from pg_control_checkpoint()")
  echo "$mode,$load,$run,$L,$C,$tli,${p:-NA,NA},$lag,$since,$gap" | tee -a "$OUT"
}

echo "summarize_wal,load,run,from,to,new_tli,promote_s,waited_for_summarizer,summarizer_lag_bytes,s_since_restartpoint,client_write_gap_s" | tee "$OUT"
for load in idle pgbench; do
  if [[ $load == pgbench ]]; then start_load; fi
  for mode in on off; do
    set_summarize "$mode"
    sleep 15
    for run in $(seq 1 "$N"); do cycle "$mode" "$load" "$run"; done
  done
  stop_load
done
echo "DONE"
