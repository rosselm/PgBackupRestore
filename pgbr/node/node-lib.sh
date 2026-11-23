# Sourced by the pgbr node-side scripts (installed as /usr/local/lib/pgbr/node-lib.sh).
set -Eeuo pipefail
export LC_ALL=C

NODE_CONF=${PGBR_NODE_CONF:-/etc/pgbr/node.conf}
[[ -r $NODE_CONF ]] || { echo "pgbr: $NODE_CONF is missing" >&2; exit 1; }
# shellcheck disable=SC1090
source "$NODE_CONF"
: "${PGBR_REPO_HOST:?missing in $NODE_CONF}"
PGBR_REPO_USER=${PGBR_REPO_USER:-postgres}
PGBR_LOG_DIR=${PGBR_LOG_DIR:-/var/log/pgbr}
HOME=${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}

# Run one gateway request on the repository host. stdin/stdout are passed through.
# Connections are multiplexed so a busy primary does not pay an SSH handshake per WAL segment.
repo_ssh() {
  local -a o=(-o BatchMode=yes -o StrictHostKeyChecking=yes
              -o ConnectTimeout="${PGBR_SSH_CONNECT_TIMEOUT:-10}"
              -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
  [[ -n ${PGBR_SSH_KEY:-} ]] && o+=(-i "$PGBR_SSH_KEY" -o IdentitiesOnly=yes)
  if [[ ${PGBR_SSH_MUX:-1} == 1 ]]; then
    o+=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/pgbr-mux-%C" -o ControlPersist=120)
  fi
  ssh "${o[@]}" "$PGBR_REPO_USER@$PGBR_REPO_HOST" "$@"
}

nlog() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >&2; }
