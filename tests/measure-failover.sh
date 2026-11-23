#!/usr/bin/env bash
# Measures what summarize_wal costs at promotion time in an UNPLANNED failover.
#
# A planned switchover (tests/measure-promotion.sh) promotes a standby that was receiving WAL a
# moment ago. In a real failover the primary is gone and nothing arrives for the whole leader-lock
# TTL before the promotion, which is exactly when a WAL summarizer goes to sleep for longer and
# longer. So this script kills the primary hard (SIGKILL Patroni and PostgreSQL, power off the
# machine) N times for each combination of  summarize_wal = on|off  and  load = idle|pgbench.
#
# Per failover it records:
#   quiet_s                kill -> "received promote request" on the new primary (no WAL arriving)
#   promote_s              "received promote request" -> "ready to accept connections"
#   waited_for_summarizer  1 if the log shows "still waiting for WAL summarization"
#   client_write_gap_s     longest gap between two heartbeat rows: the outage an application sees
#
#   N=5 OUT=docs/failover-measurements.csv tests/measure-failover.sh
#
# Leaves the cluster as it found it (summarize_wal = on, no load, bench database dropped).
source "$(dirname "$0")/lib.sh"
N=${N:-5}
LOADS=${LOADS:-idle pgbench}
OUT=${OUT:-$TESTS_DIR/../docs/failover-measurements.csv}
BENCH_ENV="PGHOST=$(tr ' ' ',' <<<"$PG_NODES") PGUSER=postgres PGPASSWORD=$PG_SUPERUSER_PASSWORD PGTARGETSESSIONATTRS=read-write PGCONNECT_TIMEOUT=2"

writable() { [[ "$(nsql "$1" postgres "select pg_is_in_recovery()" 2>/dev/null || true)" == f ]]; }
wait_writable() { local i; for i in $(seq 1 180); do writable "$1" && return 0; sleep 1; done; return 1; }

set_summarize() {
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
  sleep 20
}

cleanup() {
  stop_load
  if [[ -n $DOWN ]]; then orb start "$DOWN" >/dev/null 2>&1 || true; DOWN=""; "$TESTS_DIR/../lab/05-hosts.sh" >/dev/null 2>&1 || true; fi
  set_summarize on || true
  wait_writable "$(leader)" && nsql "$(leader)" postgres "drop database if exists bench" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cycle() { # mode load run
  local mode=$1 load=$2 run=$3 OLD NEW t0 p tli gap i
  wait_replicas 2
  OLD=$(leader)
  wait_writable "$OLD"
  sleep $(( 10 + RANDOM % 20 ))
  t0=$(date +%s)
  orb -m "$OLD" sudo bash -c 'systemctl kill -s KILL patroni; pkill -9 -x postgres; true'
  orb stop "$OLD" >/dev/null
  DOWN="$OLD"
  NEW=$(wait_leader "$OLD") || { echo "no new leader after killing $OLD" >&2; return 1; }
  wait_writable "$NEW" || { echo "$NEW never became writable" >&2; return 1; }
  for i in 1 2 3 4 5; do
    p=$(orb -m "$NEW" sudo journalctl -u patroni --since "@$t0" -o short-unix --no-pager | awk -v t0="$t0" '
        /received promote request/ && !p { p = $1 }
        /database system is ready to accept connections/ && p && !r { r = $1 }
        /still waiting for WAL summarization/ { w = 1 }
        END { if (p && r) printf "%.1f,%.1f,%d", p - t0, r - p, w + 0 }')
    [[ -n $p ]] && break
    sleep 2
  done
  sleep 5
  gap=$(nsql "$NEW" demo "select round(extract(epoch from max(g))::numeric, 1) from (select ts - lag(ts) over (order by ts) as g from heartbeat where ts > to_timestamp($t0) - interval '5 seconds') s")
  tli=$(nsql "$NEW" postgres "select timeline_id from pg_control_checkpoint()")
  echo "$mode,$load,$run,$OLD,$NEW,$tli,${p:-NA,NA,NA},$gap" | tee -a "$OUT"
  orb start "$OLD" >/dev/null
  DOWN=""
  "$TESTS_DIR/../lab/05-hosts.sh" >/dev/null
}

echo "summarize_wal,load,run,killed,promoted,new_tli,quiet_s,promote_s,waited_for_summarizer,client_write_gap_s" | tee "$OUT"
for load in $LOADS; do
  if [[ $load == pgbench ]]; then wait_replicas 2; start_load; fi
  for mode in on off; do
    wait_replicas 2
    set_summarize "$mode"
    sleep 15
    for run in $(seq 1 "$N"); do cycle "$mode" "$load" "$run"; done
  done
  stop_load
done
wait_replicas 2
echo "DONE"
