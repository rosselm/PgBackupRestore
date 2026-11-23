#!/usr/bin/env bash
# Runs on the Mac. Lets the postgres user of every PG node reach the repository host over SSH,
# restricted to the pgbr gateway (forced command): a node can push/fetch WAL and fetch backups of
# its own cluster, and nothing else. No shell, no forwarding, no other cluster.
# Uses the production installers; the Mac only carries the public keys and the fingerprint across.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
I="$PWD/../pgbr/install"

fp="$(orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" host-fingerprint)"
for n in $PG_NODES; do
  orb -m "$n" sudo bash "$I/install-node.sh" show-key \
    | orb -m "$BACKUP_HOST" sudo bash "$I/install-repo.sh" add-node-key --cluster "$CLUSTER_NAME"
  orb -m "$n" sudo bash "$I/install-node.sh" trust-repo --fingerprint "$fp"
  orb -m "$n" sudo bash "$I/install-node.sh" verify
done
