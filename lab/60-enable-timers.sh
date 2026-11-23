#!/usr/bin/env bash
# Runs on the Mac. Enables the scheduled jobs on the backup host and runs each unit once so a
# broken unit shows up now rather than at 01:15.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

orb -m "$BACKUP_HOST" sudo bash -c "
set -e
bash $PWD/../pgbr/install/install-repo.sh enable-timers --cluster $CLUSTER_NAME >/dev/null
echo '== first run of each unit'
for s in backup check; do
  systemctl start pgbr-\$s@$CLUSTER_NAME.service && echo \"pgbr-\$s@$CLUSTER_NAME.service: \$(systemctl show -p Result --value pgbr-\$s@$CLUSTER_NAME.service)\"
done
echo
journalctl -u pgbr-backup@$CLUSTER_NAME.service -u pgbr-check@$CLUSTER_NAME.service --no-pager -n 14 -o cat
echo
systemctl list-timers 'pgbr-*' --no-pager
"
