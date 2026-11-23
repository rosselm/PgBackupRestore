#!/usr/bin/env bash
# Runs on the Mac. Starts Patroni (first node bootstraps, the others clone it), then creates the
# backup role and a small demo schema with a heartbeat table used by the PITR tests.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
first="${PG_NODES%% *}"
ctl() { orb -m "$first" sudo -u postgres patronictl -c /etc/patroni/config.yml "$@"; }

echo "== starting Patroni on $first (bootstraps the cluster)"
orb -m "$first" sudo systemctl start patroni
for i in $(seq 1 60); do
  ctl list -f json 2>/dev/null | jq -e '.[] | select(.Role=="Leader" and .State=="running")' >/dev/null 2>&1 && break
  sleep 2
done
ctl list

for n in ${PG_NODES#* }; do
  echo "== starting Patroni on $n (clones from the leader)"
  orb -m "$n" sudo systemctl start patroni
done
for i in $(seq 1 90); do
  [[ "$(ctl list -f json 2>/dev/null | jq '[.[] | select(.State=="streaming")] | length')" == "$(( $(wc -w <<<"$PG_NODES") - 1 ))" ]] && break
  sleep 2
done
ctl list

leader="$(ctl list -f json | jq -r '.[] | select(.Role=="Leader") | .Member')"
echo "== leader is $leader: creating backup role and demo schema"
orb -m "$leader" sudo -u postgres psql -X -v ON_ERROR_STOP=1 -v pw="$PG_BACKUP_PASSWORD" <<'SQL'
select 'create role backup login replication password ' || quote_literal(:'pw')
where not exists (select from pg_roles where rolname = 'backup') \gexec
grant pg_monitor, pg_checkpoint to backup;
grant execute on function pg_switch_wal() to backup;

select 'create database demo' where not exists (select from pg_database where datname = 'demo') \gexec
\c demo
create table if not exists heartbeat (
  id   bigint generated always as identity primary key,
  ts   timestamptz not null default clock_timestamp(),
  node text not null default 'unknown',
  tli  int
);
SQL
