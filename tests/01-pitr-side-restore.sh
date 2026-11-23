#!/usr/bin/env bash
# Scenario 1 - "someone dropped a table": point-in-time recovery into a side instance.
#
# The production cluster is never touched. The backup is restored on the repository host,
# replayed to just before the accident, and the lost table is read from there.
source "$(dirname "$0")/lib.sh"
SIDE="$REPO/scratch/pitr-side"; PORT=5441
drop_side "$SIDE"

say "Create a table that matters, then note the last good moment"
lsql demo "drop table if exists orders; create table orders as select g as id, 'order ' || g as item from generate_series(1, 1000) g"
sleep 3
T_GOOD=$(now_utc)
echo "   last good moment: $T_GOOD"
sleep 3

say "The accident: DROP TABLE orders (and life goes on for a few seconds)"
lsql demo "drop table orders"
sleep 3
flush_archive
HB_EXPECTED=$(lsql demo "select count(*) from heartbeat where ts <= '$T_GOOD'")
HB_NOW=$(lsql demo "select count(*) from heartbeat")
echo "   heartbeat rows at the good moment: $HB_EXPECTED, now: $HB_NOW"

say "Restore to $T_GOOD in a side instance on $BACKUP_HOST"
bk restore --target-dir "$SIDE" --target-time "$T_GOOD" --port "$PORT" --start

say "Check what the side instance contains"
expect_eq "$(ssql $PORT demo "select count(*) from orders")" "1000" "orders table is back with all rows"
expect_eq "$(ssql $PORT demo "select count(*) from heartbeat")" "$HB_EXPECTED" "heartbeat rows match the target moment exactly"
expect_eq "$(ssql $PORT demo "select count(*) from heartbeat where ts > '$T_GOOD'")" "0" "nothing after the target was replayed"
expect_eq "$(ssql $PORT postgres "show archive_mode")" "off" "side instance cannot write into the real WAL archive"
expect_eq "$(lsql demo "select to_regclass('orders') is null")" "t" "production is untouched (table still dropped there)"

say "Bring the table back into production from the side instance (pg_dump | psql)"
L=$(leader)
bsh "$PGBIN/pg_dump -h /var/run/postgresql -p $PORT -d demo -t orders" | orb -m "$L" sudo -u postgres psql -XAtq -v ON_ERROR_STOP=1 -d demo >/dev/null
expect_eq "$(lsql demo "select count(*) from orders")" "1000" "orders restored in production"

drop_side "$SIDE"
say "Scenario 1 passed"
