#!/usr/bin/env bash
# Runs on the Mac. Lets the postgres user of every PG node reach the repository host over SSH,
# restricted to the pgbr gateway (forced command): a node can push/fetch WAL and fetch backups of
# its own cluster, and nothing else. No shell, no forwarding, no other cluster.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

keys=""
for n in $PG_NODES; do
  pub="$(orb -m "$n" sudo cat /var/lib/postgresql/.ssh/id_ed25519.pub)"
  keys+="restrict,command=\"/usr/local/bin/pgbr -c $CLUSTER_NAME gateway\" $pub"$'\n'
done

orb -m "$BACKUP_HOST" sudo bash -c '
  f=/var/lib/postgresql/.ssh/authorized_keys
  printf "%s" "$1" > "$f"; chown postgres:postgres "$f"; chmod 600 "$f"
' _ "$keys"

hostkey="$(orb -m "$BACKUP_HOST" bash -c 'cat /etc/ssh/ssh_host_ed25519_key.pub' | awk '{print $1" "$2}')"
for n in $PG_NODES; do
  orb -m "$n" sudo bash -c '
    f=/var/lib/postgresql/.ssh/known_hosts
    echo "$1 $2" > "$f"; chown postgres:postgres "$f"; chmod 600 "$f"
  ' _ "$BACKUP_HOST" "$hostkey"
  # prove the channel works and is restricted
  orb -m "$n" sudo -u postgres bash -c "
    echo x | ssh -o BatchMode=yes $BACKUP_HOST wal-missing >/dev/null && echo '== $n: gateway reachable'
    ssh -o BatchMode=yes $BACKUP_HOST 'id; ls /' 2>&1 | grep -Eq 'gateway: (unsupported request|illegal characters)' && echo '== $n: arbitrary commands refused'
    ssh -o BatchMode=yes $BACKUP_HOST bash 2>&1 | grep -q 'gateway: unsupported request' && echo '== $n: shell refused'
  "
done
