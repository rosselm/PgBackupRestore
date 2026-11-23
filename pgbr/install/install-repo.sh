#!/usr/bin/env bash
# pgbr repository-side installer. Run as root on the backup host, from a copy of the pgbr/ directory.
# The host needs the PostgreSQL server package of the cluster's major version (binaries only, no
# running instance), plus curl, jq, zstd and an SSH server. Every command is idempotent.
#
#   install-repo.sh install --cluster NAME --pgbin DIR --patroni "http://n1:8008 http://n2:8008 http://n3:8008"
#                           [--repo-dir /srv/pgbackup/NAME] [--owner postgres] [--pguser backup]
#   install-repo.sh set-password --cluster NAME      read the backup role's password from stdin into ~owner/.pgpass
#   install-repo.sh add-node-key --cluster NAME      read one node's public key from stdin, bind it to the gateway
#   install-repo.sh host-fingerprint                 the SSH host key fingerprint the nodes must pin
#   install-repo.sh enable-timers --cluster NAME     backup, check, verify and restore-drill schedules
#   install-repo.sh disable-timers --cluster NAME
set -euo pipefail
export LC_ALL=C
SRC="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "install-repo: $*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || die "run as root"

cmd=${1:-}; [[ -n $cmd ]] && shift || { sed -n '2,13p' "$0"; exit 1; }
CLUSTER=""; PGBIN=""; PATRONI=""; REPO=""; OWNER=""; PGUSER=backup
while (( $# )); do
  case $1 in
    --cluster) CLUSTER=$2; shift 2;;
    --pgbin) PGBIN=$2; shift 2;;
    --patroni) PATRONI=$2; shift 2;;
    --repo-dir) REPO=$2; shift 2;;
    --owner) OWNER=$2; shift 2;;
    --pguser) PGUSER=$2; shift 2;;
    *) die "unknown option $1";;
  esac
done
need_cluster() { [[ $CLUSTER =~ ^[A-Za-z0-9_-]+$ ]] || die "--cluster NAME is required (letters, digits, - and _)"; }
CONF="/etc/pgbr/${CLUSTER:-x}.conf"
if [[ -z $OWNER && -f $CONF ]]; then OWNER=$(sed -n 's/^PGBR_OS_USER=//p' "$CONF" | head -1); fi
OWNER=${OWNER:-postgres}
OHOME=$(getent passwd "$OWNER" | cut -d: -f6) || true
[[ -n $OHOME ]] || die "OS user $OWNER does not exist (install the PostgreSQL server package first)"
OGROUP=$(id -gn "$OWNER")
TIMERS="backup check verify restore-test"

case $cmd in
install)
  need_cluster
  [[ -n $PGBIN && -n $PATRONI ]] || die "--pgbin and --patroni are required"
  missing=""
  for c in curl jq zstd flock sha256sum tar ssh-keygen systemctl runuser; do command -v "$c" >/dev/null 2>&1 || missing+=" $c"; done
  for b in postgres pg_ctl psql pg_basebackup pg_verifybackup pg_archivecleanup pg_controldata; do [[ -x $PGBIN/$b ]] || missing+=" $PGBIN/$b"; done
  [[ -z $missing ]] || die "missing:$missing"
  incremental=1
  if [[ ! -x $PGBIN/pg_combinebackup ]]; then incremental=0; echo "install-repo: no pg_combinebackup in $PGBIN (PostgreSQL < 17): incremental backups disabled"; fi
  [[ -x $PGBIN/pg_amcheck ]] || echo "install-repo: no pg_amcheck in $PGBIN: restore drills must run without --amcheck"
  REPO=${REPO:-/srv/pgbackup/$CLUSTER}

  install -m 755 "$SRC/repo/pgbr" /usr/local/bin/pgbr
  install -d /etc/pgbr
  install -d -o "$OWNER" -g "$OGROUP" -m 700 "$REPO"
  install -d -o "$OWNER" -g "$OGROUP" -m 700 "$OHOME/.ssh"

  if [[ -f $CONF ]]; then
    echo "install-repo: $CONF already exists and was left untouched"
  else
    sed -e "s|^PGBR_CLUSTER=.*|PGBR_CLUSTER=$CLUSTER|" \
        -e "s|^PGBR_REPO=.*|PGBR_REPO=$REPO|" \
        -e "s|^PGBR_PGBIN=.*|PGBR_PGBIN=$PGBIN|" \
        -e "s|^PGBR_PATRONI_ENDPOINTS=.*|PGBR_PATRONI_ENDPOINTS=\"$PATRONI\"|" \
        -e "s|^PGBR_PGUSER=.*|PGBR_PGUSER=$PGUSER|" \
        -e "s|^PGBR_INCREMENTAL=[01]|PGBR_INCREMENTAL=$incremental|" \
        "$SRC/etc/cluster.conf.example" >"$CONF"
    printf '\n# OS user that owns the repository and runs pgbr (written by install-repo.sh)\nPGBR_OS_USER=%s\n' "$OWNER" >>"$CONF"
    chmod 644 "$CONF"
  fi

  for u in "$SRC"/systemd/pgbr-*@.service "$SRC"/systemd/pgbr-*@.timer; do
    sed "s/^User=postgres$/User=$OWNER/" "$u" >"/etc/systemd/system/$(basename "$u")"
  done
  systemctl daemon-reload
  echo "install-repo: pgbr installed for cluster '$CLUSTER' (repository $REPO, owner $OWNER, config $CONF)"
  echo "install-repo: review $CONF, then: set-password, add-node-key for every node, and only later enable-timers"
  ;;

set-password)
  need_cluster
  [[ -f $CONF ]] || die "$CONF not found: run 'install' first"
  PGUSER=$(sed -n 's/^PGBR_PGUSER=\([^ ]*\).*/\1/p' "$CONF" | head -1); PGUSER=${PGUSER:-backup}
  if [[ -t 0 ]]; then IFS= read -rs -p "Password of database role '$PGUSER': " pw || true; echo
  else IFS= read -r pw || true; fi
  [[ -n $pw ]] || die "no password given"
  f="$OHOME/.pgpass"; tmp=$(mktemp)
  [[ -f $f ]] && grep -v "^\*:\*:\*:$PGUSER:" "$f" >"$tmp" || true
  esc=${pw//\\/\\\\}; esc=${esc//:/\\:}
  printf '*:*:*:%s:%s\n' "$PGUSER" "$esc" >>"$tmp"
  install -o "$OWNER" -g "$OGROUP" -m 600 "$tmp" "$f"; rm -f "$tmp"
  echo "install-repo: password for role '$PGUSER' stored in $f"
  ;;

add-node-key)
  need_cluster
  IFS= read -r key || true
  [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "stdin is not an SSH public key"
  blob=$(awk '{print $2}' <<<"$key")
  f="$OHOME/.ssh/authorized_keys"
  install -d -o "$OWNER" -g "$OGROUP" -m 700 "$OHOME/.ssh"
  touch "$f"; chown "$OWNER:$OGROUP" "$f"; chmod 600 "$f"
  if grep -qF "$blob" "$f"; then
    echo "install-repo: this key is already registered"
  else
    printf 'restrict,command="/usr/local/bin/pgbr -c %s gateway" %s\n' "$CLUSTER" "$key" >>"$f"
    echo "install-repo: key '$(awk '{print $3" "$4}' <<<"$key")' may now use the gateway of cluster '$CLUSTER', and nothing else"
  fi
  ;;

host-fingerprint)
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'
  ;;

enable-timers)
  need_cluster
  for t in $TIMERS; do systemctl enable --now "pgbr-$t@$CLUSTER.timer" >/dev/null 2>&1; done
  systemctl list-timers "pgbr-*@$CLUSTER.timer" --no-pager
  ;;

disable-timers)
  need_cluster
  for t in $TIMERS; do systemctl disable --now "pgbr-$t@$CLUSTER.timer" >/dev/null 2>&1 || true; done
  echo "install-repo: timers for '$CLUSTER' disabled"
  ;;

*) die "unknown command '$cmd'";;
esac
