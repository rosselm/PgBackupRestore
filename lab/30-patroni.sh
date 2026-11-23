#!/usr/bin/env bash
# Runs INSIDE a PG node as root. Installs the pgbr node scripts and writes the Patroni config.
# Does not start Patroni (the caller starts the first node, waits for a leader, then the others).
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
me="$(hostname -s)"
PGBIN="/usr/lib/postgresql/$PG_VERSION/bin"
PGDATA="/var/lib/postgresql/$PG_VERSION/main"

# --- pgbr node side ---------------------------------------------------------------------------
install -d /usr/local/lib/pgbr /etc/pgbr
install -m 644 ../pgbr/node/node-lib.sh /usr/local/lib/pgbr/node-lib.sh
for s in pgbr-archive-push pgbr-archive-get pgbr-wal-backfill pgbr-patroni-callback pgbr-node-restore; do
  install -m 755 "../pgbr/node/$s" "/usr/local/bin/$s"
done
install -d -o postgres -g postgres -m 750 /var/log/pgbr
install -m 644 ../pgbr/systemd/node/pgbr-wal-backfill.service ../pgbr/systemd/node/pgbr-wal-backfill.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pgbr-wal-backfill.timer >/dev/null 2>&1
cat > /etc/pgbr/node.conf <<EOF
# pgbr node-side settings (sourced by the archive/restore scripts)
PGBR_REPO_HOST=$BACKUP_HOST
PGBR_REPO_USER=postgres
PGBR_PGDATA=$PGDATA
PGBR_PGBIN=$PGBIN
PGBR_PGPORT=5432
EOF

# SSH identity the postgres user uses to reach the repository gateway
install -d -o postgres -g postgres -m 700 /var/lib/postgresql/.ssh
if [[ ! -f /var/lib/postgresql/.ssh/id_ed25519 ]]; then
  sudo -u postgres ssh-keygen -q -t ed25519 -N '' -C "postgres@$me" -f /var/lib/postgresql/.ssh/id_ed25519
fi

# --- Patroni ----------------------------------------------------------------------------------
etcd_hosts=""
for n in $PG_NODES; do etcd_hosts+="${etcd_hosts:+,}$n:2379"; done
install -d -o postgres -g postgres -m 700 "$(dirname "$PGDATA")"
install -d -o postgres -g postgres -m 750 /etc/patroni

cat > /etc/patroni/config.yml <<EOF
scope: $CLUSTER_NAME
namespace: /service/
name: $me

restapi:
  listen: 0.0.0.0:8008
  connect_address: $me:8008

etcd3:
  hosts: $etcd_hosts

bootstrap:
  # Cluster-wide ("dynamic") settings. Stored in the DCS at first bootstrap and applied to every
  # member, so whichever node is primary archives the same way. Change later with patronictl edit-config.
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: 'on'
        # --- backup / PITR ---
        archive_mode: 'on'
        archive_command: '/usr/local/bin/pgbr-archive-push %p %f'
        archive_timeout: 60            # upper bound on how long committed WAL can stay unarchived on an idle primary
        wal_keep_size: 1GB             # what a promoted node can still backfill into the archive
        summarize_wal: 'on'            # required for incremental pg_basebackup (PG 17+)
        wal_summary_keep_time: 14d
        log_checkpoints: 'on'
      recovery_conf:
        # Replicas fall back to the archive when streaming cannot serve what they need, and a
        # promoting node probes it for existing timeline history files.
        restore_command: '/usr/local/bin/pgbr-archive-get %f %p'
  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $me:5432
  data_dir: $PGDATA
  bin_dir: $PGBIN
  pgpass: /var/lib/postgresql/.pgpass.patroni
  authentication:
    superuser:
      username: postgres
      password: '$PG_SUPERUSER_PASSWORD'
    replication:
      username: replicator
      password: '$PG_REPL_PASSWORD'
    rewind:
      username: rewind
      password: '$PG_REWIND_PASSWORD'
  parameters:
    unix_socket_directories: /var/run/postgresql
  # Lab shortcut: "samenet" = any directly connected subnet. Pin addresses in production.
  pg_hba:
    - local   all          all                      peer
    - host    all          all         127.0.0.1/32 scram-sha-256
    - host    replication  replicator  samenet      scram-sha-256
    - host    replication  backup      samenet      scram-sha-256
    - host    all          all         samenet      scram-sha-256
  callbacks:
    on_role_change: /usr/local/bin/pgbr-patroni-callback
  remove_data_directory_on_rewind_failure: true
  remove_data_directory_on_diverged_timelines: true

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
chown postgres:postgres /etc/patroni/config.yml
chmod 640 /etc/patroni/config.yml

# patronictl for humans: no -c needed
cat > /etc/profile.d/patroni.sh <<'EOF'
export PATRONICTL_CONFIG_FILE=/etc/patroni/config.yml
EOF
systemctl enable patroni >/dev/null 2>&1
echo "== $me: patroni configured"
