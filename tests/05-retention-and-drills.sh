#!/usr/bin/env bash
# Scenario 5 - housekeeping: retention, re-verification, restore drill, pause-and-inspect restore.
#
# Retention is exercised with a throw-away copy of the config (window 0 days, keep 2 fulls) so the
# real settings stay untouched.
source "$(dirname "$0")/lib.sh"
SIDE="$REPO/scratch/pitr-pause"; PORT=5444
TCONF=/tmp/pgbr-retention-test
drop_side "$SIDE"

bsh "rm -rf $TCONF; mkdir -p $TCONF; sed -e 's/^PGBR_RETENTION_DAYS=.*/PGBR_RETENTION_DAYS=0/' -e 's/^PGBR_KEEP_FULL_MIN=.*/PGBR_KEEP_FULL_MIN=2/' /etc/pgbr/$CLUSTER_NAME.conf > $TCONF/$CLUSTER_NAME.conf"
tbk() { bsh "PGBR_CONF_DIR=$TCONF pgbr -c $CLUSTER_NAME $*"; }

say "Repository before retention"
bk list
BEFORE_WAL=$(bsh "ls $REPO/wal | grep -c '\.zst$'")
FULLS=$(bk list | awk 'NR>1 && $2=="full" && $4=="ok" {print $1}')
ANCHOR=$(tail -n 2 <<<"$FULLS" | head -n 1)
echo "   $BEFORE_WAL archived segments; with 'keep 2 fulls, window 0 days' the anchor must be $ANCHOR"

say "Dry run"
N_BEFORE=$(bk list | awk 'NR>1' | wc -l | tr -d ' ')
DRY=$(tbk expire --dry-run 2>&1 || true)
grep -E 'expire: (removing backup|oldest kept)' <<<"$DRY" | sed 's/^/   /'
echo "   ...and $(grep -c '/wal/' <<<"$DRY" || true) archived WAL file(s)"
expect_eq "$(bk list | awk 'NR>1' | wc -l | tr -d ' ') backups, $(bsh "ls $REPO/wal | grep -c '\.zst$'") segments" "$N_BEFORE backups, $BEFORE_WAL segments" "dry run removed nothing"

say "Apply retention"
tbk expire 2>&1 | grep -E 'expire: (removing backup|oldest kept)' | sed 's/^/   /'
bk list
OLDEST=$(bk list | awk 'NR==2 {print $1}')
expect_eq "$OLDEST" "$ANCHOR" "oldest remaining backup is the anchor full"
KEEP_SEG=$(bsh "sed -n 's/^start_wal=//p' $REPO/base/$ANCHOR/backup.info")
OLDER=$(bsh "ls $REPO/wal | grep -E '^[0-9A-F]{24}' | awk -v k=${KEEP_SEG:8} 'substr(\$0,9,16) < k' | wc -l")
expect_eq "$(tr -d ' ' <<<"$OLDER")" "0" "no archived WAL older than the anchor's start segment (${KEEP_SEG})"
HIST=$(bsh "ls $REPO/wal/*.history | wc -l")
[[ $HIST -ge 2 ]] && pass "timeline history files are kept ($(tr -d ' ' <<<"$HIST"))" || fail "history files were removed"
echo "   archived segments: $BEFORE_WAL -> $(bsh "ls $REPO/wal | grep -c '\.zst$'")"

say "Health after retention"
flush_archive
CHECK=$(bk check || true); echo "$CHECK"
grep -q '^OK    wal: continuous' <<<"$CHECK" && pass "archive still continuous from the oldest kept backup" || fail "retention broke continuity"

say "Re-verify every stored backup (bit-rot check)"
bk verify --all 2>&1 | sed 's/^/   /'
expect_eq "$(bk list | awk 'NR>1 && $4!="ok"' | wc -l | tr -d ' ')" "0" "all remaining backups verify"

say "Detect a damaged backup: flip one byte in a data file of the oldest backup"
VICTIM=$(bsh "find $REPO/base/$ANCHOR/data/base -type f -size +16k | sort | head -1")
bsh "cp '$VICTIM' /tmp/victim.orig && printf '\\xff' | dd of='$VICTIM' bs=1 seek=8200 conv=notrunc status=none"
bk verify "$ANCHOR" >/dev/null 2>&1 && fail "corruption was not detected" || pass "pg_verifybackup caught the corruption"
expect_eq "$(bk list | awk -v id="$ANCHOR" '$1==id {print $4}')" "corrupt" "backup $ANCHOR is marked corrupt and excluded from restores"
bsh "cp /tmp/victim.orig '$VICTIM' && rm /tmp/victim.orig && sed -i 's/^status=.*/status=ok/' $REPO/base/$ANCHOR/backup.info"
bk verify "$ANCHOR" >/dev/null 2>&1 && pass "after repairing the file the backup verifies again" || fail "backup did not recover"

say "Restore drill: newest backup + all archived WAL + pg_amcheck"
bk restore-test --amcheck 2>&1 | grep 'restore-test:' | sed 's/^/   /'
expect_eq "$(bsh "cut -d' ' -f2 $REPO/state/last-restore-test")" "ok" "restore drill"

say "Pause-and-inspect restore: stop at the target, look, then decide"
T=$(now_utc); sleep 3; flush_archive
WANT=$(lsql demo "select count(*) from heartbeat where ts <= '$T'")
bk restore --target-dir "$SIDE" --target-time "$T" --action pause --port "$PORT" --start 2>&1 | grep -E 'restore: instance' | sed 's/^/   /'
expect_eq "$(ssql $PORT postgres "select pg_is_in_recovery()::text || ' ' || pg_get_wal_replay_pause_state()")" "true paused" "instance is paused in recovery at the target"
expect_eq "$(ssql $PORT demo "select count(*) from heartbeat")" "$WANT" "data visible while paused matches the target"
ssql $PORT postgres "select pg_wal_replay_resume()" >/dev/null; sleep 3
expect_eq "$(ssql $PORT postgres "select pg_is_in_recovery()")" "f" "resume promotes it"
drop_side "$SIDE"
bsh "rm -rf $TCONF"
say "Scenario 5 passed"
