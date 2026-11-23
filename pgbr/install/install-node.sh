#!/usr/bin/env bash
# pgbr node-side installer. Run as root on every PostgreSQL/Patroni node, from a copy of the pgbr/
# directory. Nothing here touches PostgreSQL or Patroni: it installs files, a dedicated SSH key and
# an (initially disabled) timer. Every command is idempotent.
#
#   install-node.sh install --repo-host HOST [--repo-user postgres] [--pg-user postgres]
#                           [--pgdata DIR] [--pgbin DIR] [--port 5432] [--socket-dir DIR]
#   install-node.sh show-key                       print the public key to register on the repository host
#   install-node.sh trust-repo --fingerprint FP    pin the repository host's SSH host key (FP from the host itself)
#   install-node.sh verify                         prove the channel works and is restricted to the gateway
#   install-node.sh enable-timer                   start the 5-minute WAL backfill retry
#   install-node.sh uninstall [--purge-key]
#
# --pgdata / --pgbin are detected from the running server when omitted (see preflight.sh).
set -euo pipefail
export LC_ALL=C
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CONF=/etc/pgbr/node.conf

die() { echo "install-node: $*" >&2; exit 1; }
need_root() { [[ $(id -u) == 0 ]] || die "run as root"; }
conf_get() { [[ -f $CONF ]] || return 0; sed -n "s/^$1=//p" "$CONF" | head -1; }   # empty on a first install

cmd=${1:-}; [[ -n $cmd ]] && shift || { sed -n '2,15p' "$0"; exit 1; }
REPO_HOST=""; REPO_USER=postgres; PGU=""; PGDATA=""; PGBIN=""; PORT=5432; SOCK=""; FP=""; PURGE=0
while (( $# )); do
  case $1 in
    --repo-host) REPO_HOST=$2; shift 2;;
    --repo-user) REPO_USER=$2; shift 2;;
    --pg-user) PGU=$2; shift 2;;
    --pgdata) PGDATA=$2; shift 2;;
    --pgbin) PGBIN=$2; shift 2;;
    --port) PORT=$2; shift 2;;
    --socket-dir) SOCK=$2; shift 2;;
    --fingerprint) FP=$2; shift 2;;
    --purge-key) PURGE=1; shift;;
    *) die "unknown option $1";;
  esac
done
PGU=${PGU:-$(conf_get PGBR_OS_USER)}; PGU=${PGU:-postgres}
PGHOME=$(getent passwd "$PGU" | cut -d: -f6) || true
[[ -n $PGHOME ]] || die "OS user $PGU does not exist"
KEY="$PGHOME/.ssh/pgbr_ed25519"
as_pg() { runuser -u "$PGU" -- "$@"; }

case $cmd in
install)
  need_root
  [[ -n $REPO_HOST ]] || die "--repo-host is required"
  missing=""
  for c in ssh ssh-keygen ssh-keyscan sha256sum stat zstd tar systemctl runuser; do command -v "$c" >/dev/null 2>&1 || missing+=" $c"; done
  [[ -z $missing ]] || die "missing commands:$missing"

  if [[ -z $SOCK ]]; then
    for d in /var/run/postgresql /run/postgresql /tmp; do [[ -S $d/.s.PGSQL.$PORT ]] && { SOCK=$d; break; }; done
    SOCK=${SOCK:-/var/run/postgresql}
  fi
  if [[ -z $PGDATA ]]; then
    PGDATA=$(as_pg psql -h "$SOCK" -p "$PORT" -d postgres -XAtqc "show data_directory" 2>/dev/null) \
      || die "could not detect the data directory (is PostgreSQL running?): pass --pgdata"
  fi
  if [[ -z $PGBIN ]]; then
    pid=$(as_pg head -1 "$PGDATA/postmaster.pid" 2>/dev/null) || die "could not detect the binary directory: pass --pgbin"
    PGBIN=$(dirname "$(readlink "/proc/$pid/exe")")
  fi
  [[ -x $PGBIN/postgres && -x $PGBIN/pg_ctl && -x $PGBIN/psql ]] || die "$PGBIN does not look like a PostgreSQL binary directory"

  install -d /usr/local/lib/pgbr /etc/pgbr
  install -m 644 "$SRC/node/node-lib.sh" /usr/local/lib/pgbr/node-lib.sh
  for s in pgbr-archive-push pgbr-archive-get pgbr-wal-backfill pgbr-patroni-callback pgbr-node-restore; do
    install -m 755 "$SRC/node/$s" "/usr/local/bin/$s"
  done
  install -d -o "$PGU" -g "$(id -gn "$PGU")" -m 750 /var/log/pgbr

  new=$(mktemp)
  cat >"$new" <<EOF
# pgbr node-side settings (written by install-node.sh; sourced by the pgbr-* scripts on this node)
PGBR_REPO_HOST=$REPO_HOST
PGBR_REPO_USER=$REPO_USER
PGBR_SSH_KEY=$KEY
PGBR_OS_USER=$PGU
PGBR_PGDATA=$PGDATA
PGBR_PGBIN=$PGBIN
PGBR_PGPORT=$PORT
PGBR_SOCKET_DIR=$SOCK
EOF
  if [[ -f $CONF ]] && ! cmp -s "$new" "$CONF"; then
    cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
    echo "install-node: $CONF existed with different content; the previous version was kept as a .bak file"
  fi
  install -m 644 "$new" "$CONF"; rm -f "$new"

  install -d -o "$PGU" -g "$(id -gn "$PGU")" -m 700 "$PGHOME/.ssh"
  if [[ ! -f $KEY ]]; then
    as_pg ssh-keygen -q -t ed25519 -N '' -C "pgbr $PGU@$(hostname -s)" -f "$KEY"
  fi

  for u in pgbr-wal-backfill.service pgbr-wal-backfill.timer; do
    sed "s/^User=postgres$/User=$PGU/" "$SRC/systemd/node/$u" >"/etc/systemd/system/$u"
  done
  systemctl daemon-reload

  echo "install-node: installed on $(hostname -s) (PGDATA=$PGDATA, PGBIN=$PGBIN, socket $SOCK:$PORT)"
  echo "install-node: public key to register on $REPO_HOST:"
  cat "$KEY.pub"
  ;;

show-key)
  [[ -f $KEY.pub ]] || die "no key yet: run 'install' first"
  cat "$KEY.pub"
  ;;

trust-repo)
  need_root
  host=$(conf_get PGBR_REPO_HOST); [[ -n $host ]] || die "$CONF has no PGBR_REPO_HOST: run 'install' first"
  [[ -n $FP ]] || die "--fingerprint is required. Get it ON the repository host:  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  line=$(ssh-keyscan -T 10 -t ed25519 "$host" 2>/dev/null | head -1)
  [[ -n $line ]] || die "could not read the SSH host key of $host"
  seen=$(ssh-keygen -lf - <<<"$line" | awk '{print $2}')
  [[ $seen == "$FP" ]] || die "host key of $host is $seen, expected $FP: NOT trusting it"
  kh="$PGHOME/.ssh/known_hosts"
  touch "$kh"; chown "$PGU:$(id -gn "$PGU")" "$kh"; chmod 600 "$kh"
  as_pg ssh-keygen -q -R "$host" -f "$kh" >/dev/null 2>&1 || true
  echo "$line" >>"$kh"
  echo "install-node: $host pinned with fingerprint $FP"
  ;;

verify)
  need_root
  # shellcheck disable=SC2016
  as_pg bash -c '. /usr/local/lib/pgbr/node-lib.sh
    echo probe | repo_ssh wal-missing >/dev/null || { echo "install-node: the gateway did not answer" >&2; exit 1; }
    out=$(repo_ssh "id; uname -a" 2>&1 || true)
    grep -q "gateway:" <<<"$out" || { echo "install-node: the key is NOT restricted to the gateway: $out" >&2; exit 1; }'
  echo "install-node: $(hostname -s) reaches the repository gateway, and nothing but the gateway"
  ;;

enable-timer)
  need_root
  systemctl enable --now pgbr-wal-backfill.timer >/dev/null 2>&1
  echo "install-node: pgbr-wal-backfill.timer is $(systemctl is-active pgbr-wal-backfill.timer)"
  ;;

uninstall)
  need_root
  systemctl disable --now pgbr-wal-backfill.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pgbr-wal-backfill.service /etc/systemd/system/pgbr-wal-backfill.timer
  systemctl daemon-reload
  rm -f /usr/local/bin/pgbr-archive-push /usr/local/bin/pgbr-archive-get /usr/local/bin/pgbr-wal-backfill \
        /usr/local/bin/pgbr-patroni-callback /usr/local/bin/pgbr-node-restore /usr/local/lib/pgbr/node-lib.sh "$CONF"
  rm -f "$PGHOME"/.ssh/pgbr-mux-* 2>/dev/null || true
  (( PURGE )) && rm -f "$KEY" "$KEY.pub"
  echo "install-node: removed from $(hostname -s). Make sure archive_command / restore_command / callbacks no longer point at pgbr."
  ;;

*) die "unknown command '$cmd'";;
esac
