#!/usr/bin/env bash
# Runs on the Mac. Rehearses docs/PRODUCTION-ROLLOUT.md against the lab.
#
#   lab/rehearse-rollout.sh off          # production had archive_mode = off  (needs the rolling restart)
#   lab/rehearse-rollout.sh placeholder  # production had archive_mode = on, archive_command = /bin/true
#
# Part A strips the lab back to "a Patroni cluster nobody has set up backups for": no pgbr files,
# no keys, no backup role, no callback, no archiving, an empty backup host. The application
# workload keeps running throughout.
# Part B then performs the rollout exactly as the guide describes it, with the same installers,
# and measures what the application saw: every write gap longer than 1.6 s, and every PostgreSQL
# restart on the node that was primary at the time.
source "$(dirname "$0")/../tests/lib.sh"
VARIANT=${1:?usage: rehearse-rollout.sh off|placeholder}
[[ $VARIANT == off || $VARIANT == placeholder ]] || { echo "variant must be off or placeholder" >&2; exit 1; }
I="$TESTS_DIR/../pgbr/install"
PCFG=/etc/patroni/config.yml
BACKUP_IP=$(orb -m "$BACKUP_HOST" bash -c "getent hosts $BACKUP_HOST | awk '{print \$1}' | head -1" </dev/null)

node() { local n=$1; shift; orb -m "$n" sudo "$@" </dev/null; }
pstart() { nsql "$1" postgres "select pg_postmaster_start_time()"; }
writable() { [[ "$(nsql "$1" postgres "select pg_is_in_recovery()" 2>/dev/null || true)" == f ]]; }
wait_writable() { local i; for i in $(seq 1 120); do writable "$1" && return 0; sleep 1; done; return 1; }
applied() { # setting value : true when every node reports it
  local n; for n in $PG_NODES; do [[ "$(nsql "$n" postgres "show $1" 2>/dev/null || true)" == "$2" ]] || return 1; done
}
wait_applied() { local i; for i in $(seq 1 45); do applied "$1" "$2" && return 0; sleep 2; done; fail "$1 did not become '$2' on every node"; }
pending() { cluster_json | jq -r '[.[] | select(."Pending restart" != null and ."Pending restart" != "") | .Member] | join(" ")'; }

# Edit a node's Patroni file the way an operator would (in the lab: with a few lines of Python).
patroni_yaml() { # node, python body operating on dict c
  orb -m "$1" sudo python3 - "$PCFG" <<PY
import sys, yaml
f = sys.argv[1]; c = yaml.safe_load(open(f)); pg = c['postgresql']
$2
yaml.safe_dump(c, open(f, 'w'), default_flow_style=False, sort_keys=False)
PY
  node "$1" systemctl reload patroni
}

# The guide's rolling restart: replicas one at a time, switchover, then the former primary.
rolling_restart() {
  local r L C
  for r in $(replicas); do
    echo "   restarting replica $r"; ctl restart "$CLUSTER_NAME" "$r" --force >/dev/null; wait_replicas 2
  done
  L=$(leader); C=$(replicas | head -1)
  echo "   switchover $L -> $C"; ctl switchover --leader "$L" --candidate "$C" --force >/dev/null
  wait_writable "$C"; wait_replicas 2
  echo "   restarting former primary $L"; ctl restart "$CLUSTER_NAME" "$L" --force >/dev/null; wait_replicas 2
}

# =============================================================================================
say "PART A - strip the lab back to a cluster without any backup tooling (variant: $VARIANT)"
orb -m "$BACKUP_HOST" sudo bash -c "
  bash $I/install-repo.sh disable-timers --cluster $CLUSTER_NAME >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pgbr-*@.service /etc/systemd/system/pgbr-*@.timer /usr/local/bin/pgbr /etc/pgbr/$CLUSTER_NAME.conf
  systemctl daemon-reload
  rm -f /var/lib/postgresql/.ssh/authorized_keys /var/lib/postgresql/.pgpass
  rm -rf /srv/pgbackup/$CLUSTER_NAME.before-rehearsal
  [[ -d /srv/pgbackup/$CLUSTER_NAME ]] && mv /srv/pgbackup/$CLUSTER_NAME /srv/pgbackup/$CLUSTER_NAME.before-rehearsal
  echo $CLUSTER_NAME > /etc/pgbr/LAB" </dev/null
for n in $PG_NODES; do
  orb -m "$n" sudo bash -c "
    bash $I/install-node.sh uninstall --purge-key >/dev/null 2>&1 || true
    rm -f /var/lib/postgresql/.ssh/id_ed25519 /var/lib/postgresql/.ssh/id_ed25519.pub /var/lib/postgresql/.ssh/known_hosts*
    pkill -u postgres -f pgbr-mux >/dev/null 2>&1 || true
    install -d /etc/pgbr && echo $CLUSTER_NAME > /etc/pgbr/LAB" </dev/null
  patroni_yaml "$n" "
pg.pop('callbacks', None)
pg['pg_hba'] = [l for l in pg['pg_hba'] if ' backup ' not in ' ' + ' '.join(l.split()) + ' ']"
done
if [[ $VARIANT == off ]]; then
  ctl edit-config --force -s postgresql.parameters.archive_mode=off -s postgresql.parameters.archive_command=null \
    -s postgresql.parameters.archive_timeout=null -s postgresql.parameters.summarize_wal=null \
    -s postgresql.parameters.wal_summary_keep_time=null -s postgresql.parameters.wal_keep_size=null \
    -s postgresql.recovery_conf=null >/dev/null
  sleep 12
  rolling_restart
  wait_applied archive_mode off
else
  ctl edit-config --force -s postgresql.parameters.archive_mode=on -s postgresql.parameters.archive_command=/bin/true \
    -s postgresql.parameters.archive_timeout=null -s postgresql.parameters.summarize_wal=null \
    -s postgresql.parameters.wal_summary_keep_time=null -s postgresql.parameters.wal_keep_size=null \
    -s postgresql.recovery_conf=null >/dev/null
  wait_applied archive_command /bin/true
fi
wait_writable "$(leader)"
lsql postgres "do \$\$ begin if exists (select from pg_roles where rolname = 'backup') then execute 'drop owned by backup'; execute 'drop role backup'; end if; end \$\$"
wait_replicas 2
expect_eq "$(pending)" "" "no member is waiting for a restart"
show_cluster
echo "   before-state as the preflight sees it on the primary:"
node "$(leader)" bash "$I/preflight.sh" | sed -n '/^== What this means/,$p' | sed 's/^/   /'

# =============================================================================================
say "PART B - the rollout, as in docs/PRODUCTION-ROLLOUT.md"
sleep 3
T0=$(now_utc)
P0=$(leader)

say "B1. Backup host: install pgbr and the repository (no production impact)"
orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" install --cluster "$CLUSTER_NAME" --pgbin "$PGBIN" \
  --patroni "$(for n in $PG_NODES; do printf 'http://%s:8008 ' "$n"; done | sed 's/ $//')" </dev/null | sed 's/^/   /'
orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" set-password --cluster "$CLUSTER_NAME" <<<"$PG_BACKUP_PASSWORD" | sed 's/^/   /'

say "B2. Every node: install the node side (files, dedicated key; nothing is activated)"
for n in $PG_NODES; do node "$n" bash "$I/install-node.sh" install --repo-host "$BACKUP_HOST" | sed -n '1s/^/   /p'; done

say "B3. Trust: register each node key on the backup host, pin its host key, verify the restriction"
FP=$(orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" host-fingerprint </dev/null)
for n in $PG_NODES; do
  orb -m "$n" sudo bash "$I/install-node.sh" show-key </dev/null | orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" add-node-key --cluster "$CLUSTER_NAME" >/dev/null
  node "$n" bash "$I/install-node.sh" trust-repo --fingerprint "$FP" >/dev/null
  node "$n" bash "$I/install-node.sh" verify | sed 's/^/   /'
done

say "B4. Database role and pg_hba (SQL on the primary, pg_hba reload through Patroni)"
orb -m "$(leader)" sudo -u postgres psql -XAtq -v ON_ERROR_STOP=1 -v pw="$PG_BACKUP_PASSWORD" <<'SQL'
select 'create role backup login replication password ' || quote_literal(:'pw') \gexec
grant pg_monitor, pg_checkpoint to backup;
grant execute on function pg_switch_wal() to backup;
SQL
for n in $PG_NODES; do
  patroni_yaml "$n" "
pg['pg_hba'][2:2] = ['host replication backup $BACKUP_IP/32 scram-sha-256', 'host postgres backup $BACKUP_IP/32 scram-sha-256']"
done
sleep 12
for n in $PG_NODES; do
  bsh "$PGBIN/psql 'host=$n user=backup dbname=postgres connect_timeout=5' -XAtqc 'select 1'" >/dev/null || fail "backup role cannot log in on $n"
done
pass "role 'backup' can reach all three nodes from the backup host"

say "B5a. Cluster-wide settings that only need a reload"
for n in $PG_NODES; do printf -v "S0_$n" '%s' "$(pstart "$n")"; done     # (macOS ships bash 3.2: no associative arrays)
SETS=(-s postgresql.parameters.archive_command='/usr/local/bin/pgbr-archive-push %p %f'
      -s postgresql.parameters.archive_timeout=60 -s postgresql.parameters.wal_keep_size=1GB
      -s postgresql.parameters.summarize_wal=on -s postgresql.parameters.wal_summary_keep_time=14d
      -s postgresql.recovery_conf.restore_command='/usr/local/bin/pgbr-archive-get %f %p')
ctl edit-config --force "${SETS[@]}" >/dev/null
# (while archive_mode is off PostgreSQL shows archive_command as "(disabled)", so it is checked after B5b)
[[ $VARIANT == off ]] || wait_applied archive_command '/usr/local/bin/pgbr-archive-push %p %f'
wait_applied summarize_wal on
wait_applied wal_keep_size 1GB
for n in $PG_NODES; do v="S0_$n"; [[ "$(pstart "$n")" == "${!v}" ]] || fail "$n was restarted by a reload-only change"; done
pass "applied on all nodes by reload; no PostgreSQL restart on any node"
expect_eq "$(pending)" "" "no member is waiting for a restart"

if [[ $VARIANT == off ]]; then
  say "B5b. archive_mode = on: needs a restart of every member, done rolling"
  ctl edit-config --force -s postgresql.parameters.archive_mode=on >/dev/null
  for i in $(seq 1 30); do [[ $(wc -w <<<"$(pending)") == 3 ]] && break; sleep 2; done
  expect_eq "$(wc -w <<<"$(pending)" | tr -d ' ')" "3" "Patroni flags all three members as 'Pending restart'"
  rolling_restart
  wait_applied archive_mode on
  wait_applied archive_command '/usr/local/bin/pgbr-archive-push %p %f'
  expect_eq "$(pending)" "" "no member is waiting for a restart"
else
  say "B5b. archive_mode was already on: nothing to restart"
  wait_applied archive_mode on
fi

say "B5c. Is WAL arriving in the repository?"
flush_archive
expect_eq "$(lsql postgres "select (last_failed_time is null or last_archived_time > last_failed_time) from pg_stat_archiver")" "t" "archiver on the primary is succeeding"
N=$(bsh "ls $REPO/wal | grep -c '\.zst$'")
[[ $N -ge 1 ]] && pass "$N segment(s) in the repository" || fail "nothing archived"

say "B6. Promotion hook (optional) and the backfill timer"
for n in $PG_NODES; do
  patroni_yaml "$n" "
pg['callbacks'] = {'on_role_change': '/usr/local/bin/pgbr-patroni-callback'}"
  node "$n" bash "$I/install-node.sh" enable-timer | sed 's/^/   /'
done

say "B7. First full backup, health check, restore drill, schedules"
bk backup --type full 2>&1 | grep -E 'backup .*: (OK|added)' | sed 's/^/   /'
bk restore-test --amcheck 2>&1 | grep 'restore-test:' | sed 's/^/   /'
flush_archive
CHECK=$(bk check) && RC=0 || RC=$?
echo "$CHECK" | sed 's/^/   /'
expect_eq "$RC" "0" "pgbr check exit status"
orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" enable-timers --cluster "$CLUSTER_NAME" </dev/null | sed 's/^/   /'

say "B8. Acceptance: point-in-time restore to a moment AFTER the first backup, in a side instance"
SIDE="$REPO/scratch/rollout-accept"; drop_side "$SIDE"
sleep 3; T_ACC=$(now_utc); sleep 2; flush_archive
WANT=$(lsql demo "select count(*) from heartbeat where ts <= '$T_ACC'")
bk restore --target-dir "$SIDE" --target-time "$T_ACC" --port 5446 --start 2>&1 | grep -E 'restore: instance' | sed 's/^/   /'
expect_eq "$(ssql 5446 demo "select count(*) from heartbeat")" "$WANT" "heartbeat rows at $T_ACC"
drop_side "$SIDE"

# =============================================================================================
say "What the application saw during the whole rollout (since $T0)"
sleep 4
GAPS=$(lsql demo "select coalesce(string_agg(to_char(ts at time zone 'UTC', 'HH24:MI:SS') || ' ' || round(extract(epoch from g)::numeric, 1) || 's', ', ' order by ts), 'none') from (select ts, ts - lag(ts) over (order by ts) as g from heartbeat where ts > '$T0') s where g > interval '1.6 seconds'")
MAXGAP=$(lsql demo "select round(extract(epoch from max(g))::numeric, 1) from (select ts - lag(ts) over (order by ts) as g from heartbeat where ts > '$T0') s")
echo "   write gaps longer than 1.6 s: $GAPS"
echo "   longest write gap: ${MAXGAP}s    primary before: $P0    primary after: $(leader)"
if [[ $VARIANT == off ]]; then
  awk -v g="$MAXGAP" 'BEGIN { exit !(g < 15) }' && pass "one switchover-sized interruption, nothing else" || fail "write outage of ${MAXGAP}s"
  expect_eq "$(grep -o 's' <<<"$GAPS" | wc -l | tr -d ' ')" "1" "number of write interruptions"
else
  expect_eq "$GAPS" "none" "write interruptions"
fi
bsh "rm -rf /srv/pgbackup/$CLUSTER_NAME.before-rehearsal"
say "Rehearsal ($VARIANT) passed"
