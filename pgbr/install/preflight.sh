#!/usr/bin/env bash
# pgbr preflight: read-only discovery on ONE PostgreSQL/Patroni node before a rollout.
# Changes nothing. Run it on every node (as root, or as the PostgreSQL OS user) and keep the output.
#
#   preflight.sh [--pg-user postgres] [--port 5432] [--socket-dir DIR] [--patroni-config FILE]
#
# The last section ("What this means for the rollout") turns the findings into the decisions the
# rollout guide asks for. Probes that fail print "unknown" instead of stopping the script.
set -uo pipefail
export LC_ALL=C

PGUSER_OS=postgres; PORT=5432; SOCK=""; PCONF=""
while (( $# )); do
  case $1 in
    --pg-user) PGUSER_OS=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --socket-dir) SOCK=$2; shift 2;;
    --patroni-config) PCONF=$2; shift 2;;
    -h|--help) sed -n '2,9p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 1;;
  esac
done

as_pg() { if [[ $(id -un) == "$PGUSER_OS" ]]; then "$@"; else runuser -u "$PGUSER_OS" -- "$@"; fi; }
PSQL=$(command -v psql || true)
if [[ -z $SOCK ]]; then
  for d in /var/run/postgresql /run/postgresql /tmp; do [[ -S $d/.s.PGSQL.$PORT ]] && { SOCK=$d; break; }; done
fi
q() { [[ -n $PSQL ]] && as_pg "$PSQL" -h "${SOCK:-/var/run/postgresql}" -p "$PORT" -d postgres -XAtq -c "$1" 2>/dev/null || echo unknown; }
gs() { q "select setting from pg_settings where name = '$1'" | head -1 | sed 's/^$/(empty)/'; }
row() { printf '  %-34s %s\n' "$1" "$2"; }
hdr() { printf '\n== %s\n' "$1"; }
ACTIONS=()
act() { ACTIONS+=("$1"); }

hdr "Host"
row "hostname" "$(hostname -f 2>/dev/null || hostname)"
row "OS" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
SEL=$(command -v getenforce >/dev/null 2>&1 && getenforce || echo "not installed")
row "SELinux" "$SEL"
row "PostgreSQL OS user / home" "$PGUSER_OS / $(getent passwd "$PGUSER_OS" | cut -d: -f6)"
for c in ssh ssh-keygen sha256sum zstd tar systemctl; do command -v "$c" >/dev/null 2>&1 || MISSING="${MISSING:-} $c"; done
row "required commands missing" "${MISSING:- none}"

hdr "PostgreSQL"
VERNUM=$(q "show server_version_num"); VER=$(q "show server_version")
PGDATA=$(q "show data_directory")
PGBIN=unknown
if [[ -r $PGDATA/postmaster.pid ]] || as_pg test -r "$PGDATA/postmaster.pid" 2>/dev/null; then
  pid=$(as_pg head -1 "$PGDATA/postmaster.pid" 2>/dev/null)
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || as_pg readlink "/proc/$pid/exe" 2>/dev/null)
  [[ -n ${exe:-} ]] && PGBIN=$(dirname "$exe")
fi
INREC=$(q "select pg_is_in_recovery()")
row "version" "$VER ($VERNUM)"
row "data directory" "$PGDATA"
row "binary directory" "$PGBIN"
row "port / socket directory" "$PORT / ${SOCK:-unknown}"
row "role right now" "$([[ $INREC == t ]] && echo replica || { [[ $INREC == f ]] && echo PRIMARY || echo unknown; })"
row "timeline" "$(q "select timeline_id from pg_control_checkpoint()")"
row "system identifier" "$(q "select system_identifier from pg_control_system()")"
row "total database size" "$(q "select pg_size_pretty(sum(pg_database_size(oid))) from pg_database")"
TBS=$(q "select count(*) from pg_tablespace where spcname not in ('pg_default','pg_global')")
row "user tablespaces" "$TBS"
row "data checksums" "$(gs data_checksums)"
row "WAL segment size" "$(q "select pg_size_pretty(setting::bigint) from pg_settings where name='wal_segment_size'")"
row "pg_wal filesystem free" "$(df -h --output=avail "$PGDATA/pg_wal" 2>/dev/null | tail -1 | tr -d ' ' || echo unknown)"

hdr "Settings that matter for backup and PITR"
AM=$(gs archive_mode); AC=$(gs archive_command); RC=$(gs restore_command)
row "archive_mode" "$AM$( [[ $(q "select pending_restart from pg_settings where name='archive_mode'") == t ]] && echo '  (PENDING RESTART)')"
row "archive_command" "$AC"
row "archive_timeout" "$(gs archive_timeout)"
row "restore_command" "$RC"
row "wal_level" "$(gs wal_level)"
row "full_page_writes" "$(gs full_page_writes)"
row "wal_keep_size (MB)" "$(gs wal_keep_size)"
row "wal_log_hints" "$(gs wal_log_hints)"
SW=$(q "select setting from pg_settings where name='summarize_wal'"); row "summarize_wal" "${SW:-n/a before PostgreSQL 17}"
MWS=$(gs max_wal_senders); USED_WS=$(q "select count(*) from pg_stat_replication")
MRS=$(gs max_replication_slots); USED_RS=$(q "select count(*) from pg_replication_slots")
row "max_wal_senders (in use)" "$MWS ($USED_WS)"
row "max_replication_slots (in use)" "$MRS ($USED_RS)"
row "shared_preload_libraries" "$(gs shared_preload_libraries)"
row "track_commit_timestamp" "$(gs track_commit_timestamp)"
row "archiver" "$(q "select 'archived='||archived_count||' last='||coalesce(last_archived_wal,'-')||' failed='||failed_count||' last_failed='||coalesce(last_failed_wal,'-') from pg_stat_archiver")"
row "settings pending restart" "$(q "select coalesce(string_agg(name, ', '), 'none') from pg_settings where pending_restart")"
row "role 'backup' exists" "$(q "select exists(select from pg_roles where rolname='backup')")"

hdr "Patroni"
if [[ -z $PCONF ]]; then
  PCONF=$(ps -eo args 2>/dev/null | awk '/[p]atroni / { for (i = NF; i > 0; i--) if ($i ~ /\.ya?ml$/) { print $i; exit } }')
fi
row "config file" "${PCONF:-unknown (pass --patroni-config)}"
row "version" "$(patroni --version 2>/dev/null || echo unknown)"
CB="unknown"; HBA_LOCAL="unknown"; SCOPE="unknown"
if [[ -n $PCONF ]] && command -v python3 >/dev/null 2>&1; then
  out=$(as_pg python3 - "$PCONF" <<'PY' 2>/dev/null
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
pg = c.get('postgresql') or {}
cb = pg.get('callbacks') or {}
dcs = [k for k in ('etcd', 'etcd3', 'consul', 'zookeeper', 'kubernetes', 'raft', 'exhibitor') if k in c]
print('scope=%s' % c.get('scope'))
print('name=%s' % c.get('name'))
print('dcs=%s' % ','.join(dcs))
print('restapi=%s' % (c.get('restapi') or {}).get('connect_address'))
print('callbacks=%s' % (', '.join('%s: %s' % kv for kv in cb.items()) or 'none'))
print('hba_local=%s' % ('yes (%d lines)' % len(pg['pg_hba']) if pg.get('pg_hba') else 'no'))
print('rest_auth=%s' % ('yes' if (c.get('restapi') or {}).get('authentication') else 'no'))
print('rest_tls=%s' % ('yes' if (c.get('restapi') or {}).get('certfile') else 'no'))
PY
)
  if [[ -n $out ]]; then
    SCOPE=$(sed -n 's/^scope=//p' <<<"$out"); CB=$(sed -n 's/^callbacks=//p' <<<"$out"); HBA_LOCAL=$(sed -n 's/^hba_local=//p' <<<"$out")
    row "scope (cluster name)" "$SCOPE"
    row "member name" "$(sed -n 's/^name=//p' <<<"$out")"
    row "DCS" "$(sed -n 's/^dcs=//p' <<<"$out")"
    row "REST API address" "$(sed -n 's/^restapi=//p' <<<"$out")  (auth: $(sed -n 's/^rest_auth=//p' <<<"$out"), TLS: $(sed -n 's/^rest_tls=//p' <<<"$out"))"
    row "callbacks" "$CB"
    row "pg_hba managed in this file" "$HBA_LOCAL"
  fi
fi
if [[ -n $PCONF ]] && command -v patronictl >/dev/null 2>&1; then
  echo "  cluster-wide (DCS) configuration, backup-relevant lines:"
  as_pg patronictl -c "$PCONF" show-config 2>/dev/null </dev/null \
    | grep -nE 'archive_|restore_command|recovery_conf|summarize_wal|wal_keep|wal_summary|pg_hba|use_slots|use_pg_rewind|synchronous_mode|ttl|loop_wait' | sed 's/^/    /' || true
  echo "  members:"
  as_pg patronictl -c "$PCONF" list 2>/dev/null </dev/null | sed 's/^/    /' || true
fi

# ----------------------------------------------------------------------------------------------
hdr "What this means for the rollout"
if [[ $VERNUM =~ ^[0-9]+$ ]]; then
  if   (( VERNUM < 140000 )); then act "PostgreSQL $VER is older than 14: pgbr was not written for it (needs pg_get_wal_replay_pause_state). Do not roll out without testing."
  elif (( VERNUM < 170000 )); then act "PostgreSQL $VER: no incremental backups. Set PGBR_INCREMENTAL=0 and leave summarize_wal out. Only 17 was tested in the lab."
  else act "PostgreSQL $VER: incrementals possible (summarize_wal = on, reload only). Lab-tested major version is 17."
  fi
fi
case $AM in
  off) act "archive_mode is OFF: enabling it needs a RESTART of every member. Use the rolling procedure (replicas, switchover, old primary).";;
  on)  act "archive_mode is already on: no restart needed, archive_command changes with a reload.";;
  always) act "archive_mode is 'always': this design expects 'on'. Changing it needs a restart of every member; decide deliberately.";;
esac
case $AC in
  "(empty)"|""|unknown|"(disabled)") :;;      # PostgreSQL reports "(disabled)" while archive_mode is off
  /bin/true|true|"exit 0"|"cd .") act "archive_command is a placeholder ($AC): safe to replace.";;
  *pgbr-archive-push*) act "archive_command already points at pgbr.";;
  *) act "archive_command is ALREADY IN USE: '$AC'. Another tool is archiving WAL. Do not replace it until you have decided what happens to that archive and its backups.";;
esac
case $RC in
  "(empty)"|""|unknown|*pgbr-archive-get*) :;;
  *) act "restore_command is already set: '$RC'. It will be replaced; make sure nothing else depends on it.";;
esac
[[ $(gs full_page_writes) == off ]] && act "full_page_writes is off: backups from a replica are not safe. Turn it on first."
[[ $(gs wal_level) == minimal ]] && act "wal_level is minimal: archiving and replication need 'replica' (restart)."
if [[ $TBS =~ ^[0-9]+$ ]] && (( TBS > 0 )); then act "$TBS user tablespace(s): NOT supported by pgbr as built (plain-format backups need a tablespace mapping). Stop here."; fi
if [[ $MWS =~ ^[0-9]+$ && $USED_WS =~ ^[0-9]+$ ]] && (( MWS - USED_WS < 2 )); then act "max_wal_senders has fewer than 2 free connections: pg_basebackup -X stream needs 2. Raising it needs a restart."; fi
if [[ $MRS =~ ^[0-9]+$ && $USED_RS =~ ^[0-9]+$ ]] && (( MRS - USED_RS < 1 )); then act "max_replication_slots has no free slot: pg_basebackup uses a temporary one. Raising it needs a restart."; fi
case $CB in
  none|unknown) :;;
  *pgbr-patroni-callback*) :;;
  *) act "Patroni callbacks already exist ($CB). Leave them alone: the backfill timer covers the same job within 5 minutes. Optionally call pgbr-patroni-callback from the existing on_role_change script.";;
esac
[[ $HBA_LOCAL == no ]] && act "pg_hba is not in this node's Patroni file: it is managed in the DCS configuration or outside Patroni. Add the two 'backup' entries wherever it is managed."
[[ $SEL == Enforcing ]] && act "SELinux is enforcing: PostgreSQL will run ssh from archive_command. Not tested in the lab; check the audit log on first use."
[[ -n ${MISSING:-} ]] && act "Install the missing commands:${MISSING}"
[[ $SW == "" || $SW == unknown ]] || [[ $SW == on ]] || act "summarize_wal is off: needed only if you want incremental backups (reload, no restart)."
if (( ${#ACTIONS[@]} == 0 )); then echo "  nothing unusual found"; else for a in "${ACTIONS[@]}"; do echo "  - $a"; done; fi
echo
echo "Values to pass to install-node.sh on this node:  --pgdata $PGDATA --pgbin $PGBIN --port $PORT --socket-dir ${SOCK:-?}"
