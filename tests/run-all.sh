#!/usr/bin/env bash
# Runs every scenario in order against the running lab (about 7 minutes). Each scenario leaves
# the cluster healthy (1 primary + 2 streaming replicas) for the next one.
set -euo pipefail
cd "$(dirname "$0")"
for t in 0[1-6]-*.sh; do
  printf '\n\033[7m %s \033[0m\n' "$t"
  "./$t"
done
printf '\n\033[1;32mAll scenarios passed.\033[0m\n'
