#!/usr/bin/env bash
# Runs on the Mac. In-place point-in-time recovery of the WHOLE Patroni cluster: every node ends
# up at the target moment, on a new timeline. This is the destructive variant; prefer a side
# restore (pgbr restore) whenever copying a few objects back is enough.
#
#   lab/pitr-cluster.sh --target-time 2026-11-23T15:30:00+00:00 [--node pg2] [--target-timeline N]
#
# Two-phase variant, to look at the data before committing to the chosen moment:
#   lab/pitr-cluster.sh --target-time ... --pause       # stops with recovery paused at the target
#   lab/pitr-cluster.sh --resume --node pg1             # promote, hand over to Patroni, re-attach replicas
#
# The same steps, by hand, are in docs/TECHNICAL.md ("Runbook: in-place cluster PITR").
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

node=""; from=1; args=()
while (( $# )); do
  case $1 in
    --node) node=$2; shift 2;;
    --from-step) from=$2; shift 2;;      # resume after a failed step (needs --node when > 3)
    --resume) from=5; args+=("$1"); shift;;   # second half after a --pause run
    *) args+=("$1"); shift;;
  esac
done
(( ${#args[@]} )) || { echo "usage: $0 --target-time ISO8601 [--node NODE] [--target-timeline N] [--from-step N]" >&2; exit 1; }

step() { printf '\n\033[1m-- %s\033[0m\n' "$*"; }
pctl() { orb -m "$1" sudo -u postgres patronictl -c /etc/patroni/config.yml "${@:2}" </dev/null; }
anynode="${PG_NODES%% *}"

if (( from <= 3 )); then
  leader="$(pctl "$anynode" list -f json | jq -r '.[] | select(.Role=="Leader") | .Member')"
  replicas="$(pctl "$anynode" list -f json | jq -r '.[] | select(.Role!="Leader") | .Member' | xargs)"
  node="${node:-$leader}"
  echo "leader=$leader replicas=[$replicas] restore-node=$node"
fi
[[ -n $node ]] || { echo "--from-step > 3 needs --node" >&2; exit 1; }
others="$(for n in $PG_NODES; do [[ $n == "$node" ]] || printf '%s ' "$n"; done)"

if (( from <= 1 )); then
  step "1/8 save the cluster-wide (DCS) configuration"
  pctl "$anynode" show-config | orb -m "$node" sudo -u postgres tee /var/lib/postgresql/dcs-config.saved.yml >/dev/null
  echo "saved to $node:/var/lib/postgresql/dcs-config.saved.yml"
fi

if (( from <= 2 )); then
  step "2/8 stop Patroni everywhere: replicas first, the leader last (no failover, clean shutdown)"
  for n in $replicas $leader; do orb -m "$n" sudo systemctl stop patroni; echo "stopped on $n"; done
fi

if (( from <= 3 )); then
  step "3/8 remove the cluster state from the DCS (it describes a future that is about to be abandoned)"
  printf '%s\nYes I am aware\n' "$CLUSTER_NAME" | orb -m "$node" sudo -u postgres patronictl -c /etc/patroni/config.yml remove "$CLUSTER_NAME" >/dev/null
  echo "removed /service/$CLUSTER_NAME from the DCS"
fi

if (( from <= 4 )); then
  step "4/8 restore + recover on $node (PostgreSQL only, local socket, strict restore_command)"
  orb -m "$node" sudo -u postgres /usr/local/bin/pgbr-node-restore "${args[@]}" </dev/null
  if [[ " ${args[*]} " == *" --pause "* ]]; then
    cat <<EOF

Recovery is PAUSED at the target on $node and nothing is committed yet. Look at the data:
    orb -m $node sudo -u postgres psql -d <db>
Happy with it:   $0 --resume --node $node
Wrong moment:    orb -m $node sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /var/lib/postgresql/$PG_VERSION/main -m fast stop
                 $0 --target-time <other> --pause --node $node --from-step 4
EOF
    exit 0
  fi
elif [[ " ${args[*]} " == *" --resume "* ]]; then
  step "4/8 accept the paused recovery on $node: promote and shut down cleanly"
  orb -m "$node" sudo -u postgres /usr/local/bin/pgbr-node-restore --resume </dev/null
fi

step "5/8 start Patroni on $node: it adopts the recovered data directory and becomes leader"
orb -m "$node" sudo systemctl start patroni
for i in $(seq 1 60); do
  pctl "$node" list -f json 2>/dev/null | jq -e '.[] | select(.Role=="Leader" and .State=="running")' >/dev/null 2>&1 && break
  sleep 2
done
pctl "$node" list

step "6/8 make sure the cluster-wide configuration is the one saved in step 1"
# Patroni re-creates the DCS config key from patroni.dynamic.json inside the restored data directory,
# i.e. the configuration as it was when the BACKUP was taken. Re-apply today's so nothing changed
# since then (archive settings, parameters) is silently lost.
for i in $(seq 1 30); do
  [[ -n "$(pctl "$node" show-config 2>/dev/null)" ]] && break
  sleep 2
done
orb -m "$node" sudo -u postgres patronictl -c /etc/patroni/config.yml edit-config --apply /var/lib/postgresql/dcs-config.saved.yml --force </dev/null | tail -n 2

step "7/8 start Patroni on the other nodes: they rewind (or re-clone) onto the new timeline"
for n in $others; do orb -m "$n" sudo systemctl start patroni; done
want=$(( $(wc -w <<<"$PG_NODES") - 1 ))
for i in $(seq 1 150); do
  [[ "$(pctl "$node" list -f json 2>/dev/null | jq '[.[] | select(.Role=="Replica" and .State=="streaming")] | length')" == "$want" ]] && break
  sleep 2
done
pctl "$node" list

step "8/8 new full backup: the first restore point on the new timeline"
orb -m "$BACKUP_HOST" sudo -u postgres pgbr -c "$CLUSTER_NAME" backup --type full </dev/null
echo
echo "Done. The pre-PITR data directory of $node was kept next to PGDATA (*.pre-pitr.*); remove it once you are satisfied."
