#!/usr/bin/env bash
# Runs on the Mac. Builds the whole lab from nothing: 4 OrbStack machines, etcd, Patroni cluster
# (1 primary + 2 replicas), backup repository host, workload, first full backup, timers.
# Every step is idempotent; re-running continues where it stopped.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
L="$PWD"
log="$(mktemp -d)"

./00-create-vms.sh
./05-hosts.sh

echo "== installing packages on all machines (logs in $log)"
for m in $PG_NODES; do orb -m "$m" sudo bash "$L/10-packages.sh" node >"$log/pkg-$m.log" 2>&1 & done
orb -m "$BACKUP_HOST" sudo bash "$L/10-packages.sh" backup >"$log/pkg-$BACKUP_HOST.log" 2>&1 &
wait
tail -qn 1 "$log"/pkg-*.log

echo "== etcd"
for m in $PG_NODES; do orb -m "$m" sudo bash "$L/20-etcd.sh" & done; wait

echo "== Patroni config + pgbr node side"
for m in $PG_NODES; do orb -m "$m" sudo bash "$L/30-patroni.sh"; done

echo "== backup host"
orb -m "$BACKUP_HOST" sudo bash "$L/40-backup-host.sh"
./45-ssh-trust.sh

./50-start-cluster.sh
./55-workload.sh

echo "== first full backup"
orb -m "$BACKUP_HOST" sudo -u postgres pgbr -c "$CLUSTER_NAME" backup --type full
./60-enable-timers.sh
echo
echo "Lab is up. Try:  orb -m $BACKUP_HOST sudo -u postgres pgbr check"
