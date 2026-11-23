#!/usr/bin/env bash
# Runs on the Mac. Creates the OrbStack machines for the lab (idempotent).
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

existing="$(orb list -q 2>/dev/null || true)"
for m in $PG_NODES $BACKUP_HOST; do
  if grep -qx "$m" <<<"$existing"; then
    echo "== $m already exists, starting it"
    orb start "$m" >/dev/null 2>&1 || true
  else
    echo "== creating $m ($DISTRO)"
    orb create "$DISTRO" "$m"
  fi
done
orb list
