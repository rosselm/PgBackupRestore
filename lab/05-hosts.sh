#!/usr/bin/env bash
# Runs on the Mac. Pins the lab hostnames in /etc/hosts on every VM.
# OrbStack's *.orb.local DNS does not answer from inside the machines here, and static names
# are closer to a real server estate anyway. Re-run after a restart if the IPs changed.
set -euo pipefail
cd "$(dirname "$0")"
source ./lab.env

block="# BEGIN pglab"$'\n'
for m in $PG_NODES $BACKUP_HOST; do
  ip="$(orb -m "$m" bash -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -1")"
  [[ -n "$ip" ]] || { echo "could not determine IP of $m" >&2; exit 1; }
  block+="$ip $m"$'\n'
done
block+="# END pglab"

for m in $PG_NODES $BACKUP_HOST; do
  # Managed block goes first so the real IP wins over Ubuntu's "127.0.1.1 <hostname>" entry.
  orb -m "$m" sudo bash -c '
    block="$1"
    tmp="$(mktemp)"
    { printf "%s\n" "$block"; sed "/^# BEGIN pglab\$/,/^# END pglab\$/d" /etc/hosts; } > "$tmp"
    cat "$tmp" > /etc/hosts && rm -f "$tmp"
  ' _ "$block"
  echo "== $m: /etc/hosts updated"
done
printf '%s\n' "$block"
