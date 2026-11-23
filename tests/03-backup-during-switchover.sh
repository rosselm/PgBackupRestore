#!/usr/bin/env bash
# Scenario 3 - the replica we are backing up from gets promoted in the middle of the backup.
#
# pg_basebackup cannot survive its source changing role ("the standby was promoted during online
# backup"). pgbr must notice, re-read the topology from Patroni and finish from another node,
# without leaving a half backup behind.
source "$(dirname "$0")/lib.sh"
LOG=/tmp/pgbr-scenario3.log

OLD=$(leader)
say "Start a deliberately slow full backup (512 kB/s) in the background"
show_cluster
bsh "PGBR_MAX_RATE=512k pgbr -c $CLUSTER_NAME backup --type full >$LOG 2>&1" &
BGPID=$!
SRC=""
for i in $(seq 1 30); do
  SRC=$(bsh "sed -n 's/.*source=\([a-z0-9]*\) (replica).*/\1/p' $LOG | head -1" || true)
  [[ -n $SRC ]] && break
  sleep 1
done
[[ -n $SRC ]] || fail "backup did not start from a replica"
pass "backup is running from replica $SRC"
sleep 6

say "Planned switchover: promote exactly that replica ($OLD -> $SRC) while it is being backed up"
ctl switchover --leader "$OLD" --candidate "$SRC" --force | tail -n 3
wait $BGPID && RC=0 || RC=$?
echo "--- pgbr log"; bsh "cat $LOG" | sed 's/^/   /'
expect_eq "$RC" "0" "pgbr backup exit code"
bsh "grep -q 'backup .*: pg_basebackup failed' $LOG" && pass "the interrupted attempt on $SRC was detected" || fail "expected a failed first attempt"
ID=$(bsh "tail -n 1 $LOG")
FINAL=$(bk list | awk -v id="$ID" '$1==id {print $5}')
[[ -n $FINAL && $FINAL != "$SRC" ]] && pass "backup $ID completed from $FINAL instead" || fail "no completed backup from another node"
expect_eq "$(bk list | awk -v id="$ID" '$1==id {print $4}')" "ok" "backup $ID verified by pg_verifybackup"
expect_eq "$(bsh "ls -d $REPO/base/.inprogress-* 2>/dev/null | wc -l")" "0" "no half-finished backup left in the repository"
expect_eq "$(leader)" "$SRC" "new leader"
wait_replicas 2 && pass "both other nodes follow the new leader" || fail "replicas did not follow"
show_cluster
say "Scenario 3 passed"
