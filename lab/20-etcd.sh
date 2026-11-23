#!/usr/bin/env bash
# Runs INSIDE a PG node as root. Configures this node as a member of the 3-node etcd cluster.
# (Lab shortcut: etcd is co-located with PostgreSQL. Production DCS usually lives on its own hosts.)
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env
me="$(hostname -s)"

initial_cluster=""
for n in $PG_NODES; do initial_cluster+="${initial_cluster:+,}$n=http://$n:2380"; done

cat > /etc/default/etcd <<EOF
ETCD_NAME=$me
ETCD_DATA_DIR=/var/lib/etcd/$CLUSTER_NAME
ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=http://$me:2380
ETCD_ADVERTISE_CLIENT_URLS=http://$me:2379
ETCD_INITIAL_CLUSTER=$initial_cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$CLUSTER_NAME-etcd
ETCD_UNSUPPORTED_ARCH=$(dpkg --print-architecture)
EOF

systemctl enable etcd >/dev/null 2>&1
systemctl restart etcd
echo "== $me: etcd $(systemctl is-active etcd)"
