#!/usr/bin/env bash
# Scenario 6 - in-place cluster PITR in two phases: recover and PAUSE at the target, look at the
# data, pick a better moment if needed, and only then promote and rebuild the cluster.
#
# The first attempt deliberately uses a moment that is too late (damage already present); the
# operator notices while paused, rejects it and recovers again to an earlier moment.
source "$(dirname "$0")/lib.sh"

L=$(leader)
OLD_TLI=$(lsql postgres "select timeline_id from pg_control_checkpoint()")
say "Note a good moment, then damage the data, then note a (too late) second moment"
sleep 2
T_GOOD=$(now_utc)
HB_GOOD=$(lsql demo "select count(*) from heartbeat where ts <= '$T_GOOD'")
sleep 3
lsql demo "delete from heartbeat where id % 3 = 0"
sleep 3
T_TOO_LATE=$(now_utc)
HB_TOO_LATE=$(lsql demo "select count(*) from heartbeat where ts <= '$T_TOO_LATE'")
sleep 2; flush_archive
echo "   good: $T_GOOD ($HB_GOOD rows)   too late: $T_TOO_LATE ($HB_TOO_LATE rows, damage included)"

say "Phase 1, first attempt: recover to the too-late moment and pause"
"$TESTS_DIR/../lab/pitr-cluster.sh" --target-time "$T_TOO_LATE" --pause 2>&1 | grep -E 'pgbr-node-restore|^-- ' | sed 's/^/   /'
expect_eq "$(nsql "$L" postgres "select pg_get_wal_replay_pause_state()")" "paused" "recovery is paused on $L"
expect_eq "$(nsql "$L" demo "select count(*) from heartbeat")" "$HB_TOO_LATE" "inspection shows the damage is already there: reject this moment"
expect_eq "$(orb -m "$L" systemctl is-active patroni || true)" "inactive" "Patroni is still down, nothing is committed"

say "Reject it and recover again, to the good moment"
orb -m "$L" sudo -u postgres "$PGBIN/pg_ctl" -D "/var/lib/postgresql/$PG_VERSION/main" -m fast -w stop >/dev/null
"$TESTS_DIR/../lab/pitr-cluster.sh" --target-time "$T_GOOD" --pause --discard-old-pgdata --node "$L" --from-step 4 2>&1 | grep -E 'pgbr-node-restore|^-- ' | sed 's/^/   /'
expect_eq "$(nsql "$L" demo "select count(*) from heartbeat")" "$HB_GOOD" "inspection shows the undamaged data: accept this moment"

say "Phase 2: accept - promote, hand over to Patroni, re-attach the replicas, take a full backup"
"$TESTS_DIR/../lab/pitr-cluster.sh" --resume --node "$L" 2>&1 | grep -vE '^\s*$' | sed 's/^/   /'

say "Result"
NL=$(leader)
expect_eq "$NL" "$L" "leader"
NEW_TLI=$(nsql "$NL" postgres "select timeline_id from pg_control_checkpoint()")
[[ $NEW_TLI -gt $OLD_TLI ]] && pass "new timeline ($OLD_TLI -> $NEW_TLI)" || fail "timeline did not advance"
expect_eq "$(nsql "$NL" demo "select count(*) from heartbeat where ts <= '$T_GOOD'")" "$HB_GOOD" "data at the good moment is complete"
wait_replicas 2 && pass "1 primary + 2 streaming replicas" || fail "replicas missing"
flush_archive
CHECK=$(bk check || true); echo "$CHECK"
grep -q "^OK    wal: continuous .* timeline $NEW_TLI" <<<"$CHECK" && pass "archive continuous on the new timeline" || fail "archive not continuous"
orb -m "$NL" sudo bash -c 'rm -rf /var/lib/postgresql/*/main.pre-pitr.*'
say "Scenario 6 passed"
