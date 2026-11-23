#!/usr/bin/env bash
# Runs on the Mac. Installs a tiny always-on workload on the backup host: one heartbeat row per
# second, written to whichever node is currently the primary. The rows (timestamp + timeline) are
# what the PITR tests use to prove exactly which transactions a restore contains.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
hosts="$(tr ' ' ',' <<<"$PG_NODES")"
leader="$(orb -m "${PG_NODES%% *}" sudo -u postgres patronictl -c /etc/patroni/config.yml list -f json | jq -r '.[] | select(.Role=="Leader") | .Member')"

orb -m "$leader" sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d demo <<'SQL'
select 'create role app login password ''lab-app''' where not exists (select from pg_roles where rolname = 'app') \gexec
grant insert, select on heartbeat to app;
SQL

orb -m "$BACKUP_HOST" sudo bash -c "
cat > /usr/local/bin/pglab-workload <<'EOF'
#!/usr/bin/env bash
# lab workload: 1 heartbeat/second to the current primary (libpq picks the writable host)
export PGPASSWORD=lab-app
conn='host=$hosts port=5432 dbname=demo user=app target_session_attrs=read-write connect_timeout=2'
while true; do
  /usr/lib/postgresql/$PG_VERSION/bin/psql \"\$conn\" -XAtq -c \"insert into heartbeat (node, tli) values (host(inet_server_addr()), ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int)\" >/dev/null 2>&1 || true
  sleep 1
done
EOF
chmod 755 /usr/local/bin/pglab-workload
cat > /etc/systemd/system/pglab-workload.service <<'EOF'
[Unit]
Description=pglab demo workload (heartbeat rows)
After=network-online.target
[Service]
User=postgres
ExecStart=/usr/local/bin/pglab-workload
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pglab-workload >/dev/null 2>&1
systemctl is-active pglab-workload
"
