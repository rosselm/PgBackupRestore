#!/usr/bin/env bash
# Scenario 2 - the primary dies while holding WAL it never managed to archive.
#
# This is the classic hole in archive_command-based PITR under automatic failover: the promoted
# standby has the segments but already marked them "done", the dead primary had them queued.
# Proves that
#   - the promotion hook backfills the missing segments from the new primary's pg_wal
#   - pgbr check sees a continuous archive across the timeline switch
#   - backups keep working after the failover (from the remaining replica)
#   - PITR works to a moment before the failover, inside the "unarchived" window, and after the
#     failover, all starting from a backup taken BEFORE the failover
source "$(dirname "$0")/lib.sh"
SIDE="$REPO/scratch/pitr-failover"; PORT=5442
KEY=/var/lib/postgresql/.ssh/id_ed25519
drop_side "$SIDE"

OLD=$(leader)
PRE_ID=$(bk list | awk 'NR>1 && $4=="ok" {id=$1} END {print id}')
say "Start: leader is $OLD, newest backup is $PRE_ID"
show_cluster
flush_archive
T_BEFORE=$(now_utc); sleep 2

say "Break archiving on $OLD only (its repository key disappears), then keep writing"
orb -m "$OLD" sudo bash -c "mv $KEY $KEY.off; pkill -u postgres -f 'pgbr-mux' || true"
for i in 1 2 3; do sleep 3; nsql "$OLD" postgres "select pg_switch_wal()" >/dev/null; done
sleep 3
T_GAP=$(now_utc); sleep 2
nsql "$OLD" postgres "select pg_switch_wal()" >/dev/null; sleep 2
echo "   archiver on $OLD: $(nsql "$OLD" postgres "select 'last archived '||last_archived_wal||', failing on '||coalesce(last_failed_wal,'-')||', waiting='||(select count(*) from pg_ls_archive_statusdir() where name like '%.ready') from pg_stat_archiver")"
STRANDED=$(nsql "$OLD" postgres "select string_agg(replace(name, '.ready', ''), ' ' order by name) from pg_ls_archive_statusdir() where name ~ '^[0-9A-F]{24}\.ready\$'")
WAITING=$(wc -w <<<"$STRANDED" | tr -d ' ')
[[ $WAITING -ge 3 ]] && pass "$WAITING completed segments exist only on the nodes, not in the archive: $STRANDED" || fail "expected unarchived segments on $OLD"
for s in $STRANDED; do bsh "test ! -e $REPO/wal/$s.zst" || fail "$s is already archived"; done

say "Kill $OLD hard (SIGKILL Patroni + PostgreSQL, then power off the VM)"
orb -m "$OLD" sudo bash -c 'systemctl kill -s KILL patroni; pkill -9 -x postgres; true'
orb stop "$OLD" >/dev/null
DOWN="$OLD"
NEW=$(wait_leader "$OLD") || fail "no new leader elected"
pass "failover: $NEW holds the leader lock"
# Holding the lock is not the same as accepting writes: wait for the promotion to finish.
T0=$(date +%s)
for i in $(seq 1 90); do
  [[ "$(nsql "$NEW" postgres "select pg_is_in_recovery()" 2>/dev/null || true)" == f ]] && break
  sleep 1
done
expect_eq "$(nsql "$NEW" postgres "select pg_is_in_recovery()")" "f" "$NEW is writable (about $(( $(date +%s) - T0 ))s after taking the lock)"
show_cluster

say "Promotion hook on $NEW: every stranded segment must reach the archive"
for i in $(seq 1 60); do
  MISSING=""
  for s in $STRANDED; do bsh "test -e $REPO/wal/$s.zst" || MISSING+="$s "; done
  [[ -z $MISSING ]] && break
  sleep 2
done
[[ -z $MISSING ]] && pass "all $WAITING stranded segments are now in the archive" || fail "still missing from the archive: $MISSING"
for s in $STRANDED; do
  orb -m "$NEW" sudo grep -q "backfilled $s" /var/log/pgbr/backfill.log || fail "$s was not pushed by the backfill on $NEW"
done
pass "they were pushed by the backfill on $NEW"
orb -m "$NEW" sudo grep -E "backfilled ($(tr ' ' '|' <<<"$STRANDED"))" /var/log/pgbr/backfill.log | sed 's/^/   /'

sleep 3; flush_archive
T_AFTER=$(now_utc); sleep 2; flush_archive

say "Repository health across the timeline switch"
CHECK=$(bk check || true); echo "$CHECK"
grep -q '^OK    wal: continuous' <<<"$CHECK" && pass "WAL archive is continuous from the oldest backup through the failover" || fail "WAL gap"

say "Backup after the failover (must come from the remaining replica, on the new timeline)"
POST_ID=$(bk backup --type incr | tail -1)
bk list
SRC=$(bk list | awk -v id="$POST_ID" '$1==id {print $5" tli="$6}')
[[ $SRC != "$NEW"* && $SRC != "$OLD"* ]] && pass "backup $POST_ID taken from $SRC" || fail "backup came from $SRC"

check_pitr() { # label time backup-arg...
  local label=$1 t=$2; shift 2
  local want got
  want=$(lsql demo "select count(*) from heartbeat where ts <= '$t'")
  drop_side "$SIDE"
  bk restore --target-dir "$SIDE" --target-time "$t" --port "$PORT" --start "$@" 2>&1 | grep -E 'restore: (backup|instance)' | sed 's/^/   /'
  got=$(ssql $PORT demo "select count(*) from heartbeat")
  expect_eq "$got" "$want" "$label: heartbeat rows"
  echo "   rows per timeline in the restored instance: $(ssql $PORT demo "select string_agg('tli '||tli||': '||n, ', ' order by tli) from (select tli, count(*) n from heartbeat group by tli) s")"
  drop_side "$SIDE"
}

say "PITR 1/3: a moment BEFORE the failover"
check_pitr "before failover ($T_BEFORE)" "$T_BEFORE"
say "PITR 2/3: a moment whose WAL the dead primary never archived (only reachable through the backfill)"
check_pitr "inside the unarchived window ($T_GAP)" "$T_GAP" --backup "$PRE_ID"
say "PITR 3/3: a moment AFTER the failover, starting from the pre-failover backup (crosses timeline 1 -> 2)"
check_pitr "after failover ($T_AFTER)" "$T_AFTER" --backup "$PRE_ID"

say "Bring $OLD back: Patroni rejoins it as a replica"
orb start "$OLD" >/dev/null
DOWN=""
"$TESTS_DIR/../lab/05-hosts.sh" >/dev/null
orb -m "$OLD" sudo bash -c "mv $KEY.off $KEY"
wait_replicas 2 && pass "cluster is back to 1 primary + 2 streaming replicas" || fail "old primary did not rejoin"
show_cluster
say "Scenario 2 passed"
