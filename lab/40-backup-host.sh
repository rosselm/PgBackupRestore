#!/usr/bin/env bash
# Runs INSIDE the backup host as root. Installs pgbr, its config, the repository and the timers.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
PGBIN="/usr/lib/postgresql/$PG_VERSION/bin"
REPO="/srv/pgbackup/$CLUSTER_NAME"

install -m 755 ../pgbr/repo/pgbr /usr/local/bin/pgbr
install -d /etc/pgbr
install -d -o postgres -g postgres -m 700 /srv/pgbackup "$REPO"

endpoints=""
for n in $PG_NODES; do endpoints+="${endpoints:+ }http://$n:8008"; done
sed -e "s|^PGBR_CLUSTER=.*|PGBR_CLUSTER=$CLUSTER_NAME|" \
    -e "s|^PGBR_REPO=.*|PGBR_REPO=$REPO|" \
    -e "s|^PGBR_PGBIN=.*|PGBR_PGBIN=$PGBIN|" \
    -e "s|^PGBR_PATRONI_ENDPOINTS=.*|PGBR_PATRONI_ENDPOINTS=\"$endpoints\"|" \
    ../pgbr/etc/cluster.conf.example > "/etc/pgbr/$CLUSTER_NAME.conf"
chmod 644 "/etc/pgbr/$CLUSTER_NAME.conf"

# Credentials of the backup role (libpq reads ~/.pgpass)
umask 077
echo "*:*:*:backup:$PG_BACKUP_PASSWORD" > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass
umask 022
install -d -o postgres -g postgres -m 700 /var/lib/postgresql/.ssh

install -m 644 ../pgbr/systemd/*.service ../pgbr/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
echo "== $(hostname -s): pgbr installed, repository at $REPO (timers are enabled by 60-enable-timers.sh)"
