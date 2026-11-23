#!/usr/bin/env bash
# Runs INSIDE a VM as root. Installs PostgreSQL (PGDG), Patroni, etcd and helper tools.
# Usage: 10-packages.sh <role>     role = node | backup
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
role="${1:?role: node|backup}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg lsb-release jq zstd rsync openssh-client openssh-server >/dev/null

# PGDG repository
install -d /usr/share/postgresql-common/pgdg
if [[ ! -s /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ]]; then
  curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
fi
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq

# Patroni (nodes) and our restore tooling (backup host) own the data directories, so stop the
# Debian packaging from auto-creating and starting a "main" cluster on install.
install -d /etc/postgresql-common
cat > /etc/postgresql-common/createcluster.conf <<'EOF'
create_main_cluster = false
EOF

apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" >/dev/null

if [[ "$role" == "node" ]]; then
  apt-get install -y -qq patroni etcd-server etcd-client >/dev/null
  # Both ship enabled-by-default units with placeholder configs; we configure them later.
  systemctl disable --now patroni etcd >/dev/null 2>&1 || true
fi

systemctl enable --now ssh >/dev/null 2>&1 || true

echo "== $(hostname): $(/usr/lib/postgresql/${PG_VERSION}/bin/postgres --version)"
if [[ "$role" == "node" ]]; then
  echo "== $(hostname): $(patroni --version), $(etcd --version | head -1)"
fi
