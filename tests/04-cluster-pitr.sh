#!/usr/bin/env bash
# Scenario 4 - a bad release damaged data everywhere: rewind the whole Patroni cluster in place.
#
# Proves that
#   - the cluster comes back as 1 primary + 2 replicas at exactly the chosen moment, on a new timeline
#   - Patroni adopts the recovered node and re-attaches the other two by itself
#   - the archive stays consistent: the new timeline branches off, the abandoned one is kept
#   - the abandoned timeline is still reachable on purpose (--target-timeline), e.g. to fetch
#     something that was written after the chosen moment
source "$(dirname "$0")/lib.sh"
SIDE="$REPO/scratch/pitr-branch"; PORT=5443
drop_side "$SIDE"

say "Before: healthy cluster, note the last good moment"
show_cluster
OLD_TLI=$(lsql postgres "select timeline_id from pg_control_checkpoint()")
lsql demo "create table if not exists orders as select g as id, 'order ' || g as item from generate_series(1, 1000) g" 2>/dev/null
sleep 3
T_GOOD=$(now_utc)
HB_GOOD=$(lsql demo "select count(*) from heartbeat where ts <= '$T_GOOD'")
echo "   last good moment: $T_GOOD  (timeline $OLD_TLI, $HB_GOOD heartbeat rows)"
sleep 3

say "The bad release: half the heartbeat rows deleted, orders dropped. Nobody notices for a while."
lsql demo "delete from heartbeat where id % 2 = 0; drop table orders"
sleep 5
LATE_ID=$(bk backup --type incr 2>/dev/null | tail -1)     # a backup taken on the soon-to-be-abandoned branch
sleep 3; flush_archive
T_LATE=$(now_utc)
HB_LATE=$(lsql demo "select count(*) from heartbeat where ts <= '$T_LATE'")
echo "   damaged state at $T_LATE: $HB_LATE heartbeat rows; backup $LATE_ID was taken after the damage"
sleep 2; flush_archive

say "Rewind the cluster to $T_GOOD"
"$TESTS_DIR/../lab/pitr-cluster.sh" --target-time "$T_GOOD"

say "After: what the cluster contains"
L=$(leader)
NEW_TLI=$(nsql "$L" postgres "select timeline_id from pg_control_checkpoint()")
[[ $NEW_TLI -gt $OLD_TLI ]] && pass "cluster runs on a new timeline ($OLD_TLI -> $NEW_TLI)" || fail "timeline did not advance"
expect_eq "$(nsql "$L" demo "select count(*) from heartbeat where ts <= '$T_GOOD'")" "$HB_GOOD" "all heartbeat rows up to the good moment are back"
expect_eq "$(nsql "$L" demo "select count(*) from heartbeat where ts > '$T_GOOD' and tli <= $OLD_TLI")" "0" "nothing written after the good moment on the old timeline survived"
expect_eq "$(nsql "$L" demo "select count(*) from orders")" "1000" "orders table is back"
sleep 4
[[ $(nsql "$L" demo "select count(*) from heartbeat where tli = $NEW_TLI") -gt 0 ]] && pass "application writes resumed on timeline $NEW_TLI" || fail "no new writes"
for r in $(replicas); do
  expect_eq "$(nsql "$r" demo "select count(*) from heartbeat where ts <= '$T_GOOD'")" "$HB_GOOD" "replica $r has the same data"
done

say "Repository after the rewind"
flush_archive
CHECK=$(bk check || true); echo "$CHECK"
grep -q "^OK    wal: continuous .* timeline $NEW_TLI" <<<"$CHECK" && pass "archive is continuous along the new timeline" || fail "archive not continuous"
grep -q "explicit older --target-timeline: .*$LATE_ID" <<<"$CHECK" && pass "backup $LATE_ID (abandoned branch) is flagged, not offered for normal restores" || fail "abandoned-branch backup not flagged"
bk list

say "The abandoned timeline is still reachable on purpose: side restore to $T_LATE on timeline $OLD_TLI"
bk restore --target-dir "$SIDE" --target-time "$T_LATE" --target-timeline "$OLD_TLI" --port "$PORT" --start 2>&1 | grep -E 'restore: (backup|instance)' | sed 's/^/   /'
expect_eq "$(ssql $PORT demo "select count(*) from heartbeat")" "$HB_LATE" "side instance shows the damaged state of the old timeline"
drop_side "$SIDE"

say "Clean up the kept pre-PITR data directory"
orb -m "$L" sudo bash -c 'rm -rf /var/lib/postgresql/*/main.pre-pitr.*'
say "Scenario 4 passed"
