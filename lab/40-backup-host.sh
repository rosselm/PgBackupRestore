#!/usr/bin/env bash
# Runs INSIDE the backup host as root. Installs pgbr, its config, the repository and the timers.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
PGBIN="/usr/lib/postgresql/$PG_VERSION/bin"
REPO="/srv/pgbackup/$CLUSTER_NAME"

endpoints=""
for n in $PG_NODES; do endpoints+="${endpoints:+ }http://$n:8008"; done

# The same installer a production backup host gets.
bash ../pgbr/install/install-repo.sh install --cluster "$CLUSTER_NAME" --pgbin "$PGBIN" --patroni "$endpoints" --repo-dir "$REPO"
bash ../pgbr/install/install-repo.sh set-password --cluster "$CLUSTER_NAME" <<<"$PG_BACKUP_PASSWORD"
# Marks this machine as part of the lab; the destructive test scenarios refuse to run without it.
echo "$CLUSTER_NAME" > /etc/pgbr/LAB
echo "== $(hostname -s): pgbr installed, repository at $REPO (timers are enabled by 60-enable-timers.sh)"
