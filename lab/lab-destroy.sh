#!/usr/bin/env bash
# Runs on the Mac. Deletes the four lab machines and everything in them (cluster, repository).
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
read -r -p "Delete machines [$PG_NODES $BACKUP_HOST] and all their data? Type 'destroy': " answer
[[ $answer == destroy ]] || { echo "aborted"; exit 1; }
for m in $PG_NODES $BACKUP_HOST; do orb delete -f "$m" && echo "deleted $m"; done
