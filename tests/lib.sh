# Shared helpers for the lab scenario tests (sourced; everything runs from the Mac through orb).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/../lab/lab.env"
FIRST="${PG_NODES%% *}"
REPO="/srv/pgbackup/$CLUSTER_NAME"
PGBIN="/usr/lib/postgresql/$PG_VERSION/bin"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '   \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
expect_eq() { [[ "$1" == "$2" ]] && pass "$3 ($1)" || fail "$3: got '$1', expected '$2'"; }

# Machines a test has powered off. "orb -m <machine>" silently boots a stopped machine, so every
# helper that walks the node list must skip these or it resurrects the node under test.
DOWN=""

# patronictl on any node that answers
ctl() {
  local n
  for n in $PG_NODES; do
    [[ " $DOWN " == *" $n "* ]] && continue
    # </dev/null: never let a status lookup swallow the stdin of a surrounding pipeline
    if orb -m "$n" sudo -u postgres patronictl -c /etc/patroni/config.yml "$@" 2>/dev/null </dev/null; then return 0; fi
  done
  return 1
}
cluster_json() { ctl list -f json; }
leader()   { cluster_json | jq -r '.[] | select(.Role=="Leader" and .State=="running") | .Member' | head -1; }
replicas() { cluster_json | jq -r '.[] | select(.Role=="Replica") | .Member'; }
show_cluster() { ctl list || true; }

# SQL on a node as the postgres superuser:  nsql NODE DB "sql"
nsql() { local n=$1 db=$2; shift 2; orb -m "$n" sudo -u postgres psql -XAtq -v ON_ERROR_STOP=1 -d "$db" -c "$*"; }
lsql() { nsql "$(leader)" "$@"; }
# pgbr on the repository host
bk() { orb -m "$BACKUP_HOST" sudo -u postgres pgbr -c "$CLUSTER_NAME" "$@"; }
# shell on the repository host as postgres
bsh() { orb -m "$BACKUP_HOST" sudo -u postgres bash -c "$1"; }
# SQL on a side instance restored on the repository host:  ssql PORT DB "sql"
ssql() { local p=$1 db=$2; shift 2; orb -m "$BACKUP_HOST" sudo -u postgres psql -h /var/run/postgresql -p "$p" -XAtq -d "$db" -c "$*"; }

now_utc() { lsql postgres "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"+00:00\"')"; }

wait_leader() { # optional: name the leader must NOT be
  local not=${1:-} i l
  for i in $(seq 1 90); do
    l=$(leader || true)
    if [[ -n $l && $l != "$not" ]]; then echo "$l"; return 0; fi
    sleep 2
  done
  return 1
}
wait_replicas() { # number of streaming replicas expected
  local want=$1 i
  for i in $(seq 1 150); do
    [[ "$(cluster_json 2>/dev/null | jq '[.[] | select(.Role=="Replica" and .State=="streaming")] | length')" == "$want" ]] && return 0
    sleep 2
  done
  return 1
}

# Close the current WAL segment and wait until the archiver has shipped it.
flush_archive() {
  local l seg i
  l=$(leader)
  # Patroni reports the lock holder as leader before its promotion has finished
  for i in $(seq 1 90); do
    [[ "$(nsql "$l" postgres "select pg_is_in_recovery()" 2>/dev/null || true)" == f ]] && break
    sleep 1
  done
  seg=$(nsql "$l" postgres "select pg_walfile_name(pg_switch_wal())")
  for i in $(seq 1 60); do
    [[ "$(nsql "$l" postgres "select coalesce(last_archived_wal,'') >= '$seg' from pg_stat_archiver")" == t ]] && return 0
    sleep 1
  done
  echo "archive did not catch up to $seg" >&2; return 1
}

drop_side() { # dir
  bsh "$PGBIN/pg_ctl -D '$1' -m immediate stop >/dev/null 2>&1; rm -rf '$1' '$1.log'" || true
}
