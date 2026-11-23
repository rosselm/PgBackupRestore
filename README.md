# PgBackupRestore

A lab for scheduled base backups and point-in-time recovery of a **Patroni-managed PostgreSQL
cluster (1 primary + 2 replicas)** using only native PostgreSQL tools: `pg_basebackup`,
`pg_verifybackup`, `pg_combinebackup`, `pg_archivecleanup`, `pg_amcheck`.

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — what was built and why, trade-offs, what to change for production
* [docs/TECHNICAL.md](docs/TECHNICAL.md) — how every piece works, configuration, runbooks, test results

## Layout

| Directory | Contents |
|---|---|
| `pgbr/` | the tooling itself: `repo/pgbr` (backup host CLI), `node/` (archive, restore, backfill, in-place PITR scripts), `systemd/` (timers), `etc/` (config template). This is the part that travels to a real environment. |
| `lab/` | builds the OrbStack lab: 3 PostgreSQL/Patroni/etcd machines + 1 backup host |
| `tests/` | six failure and recovery scenarios that double as the acceptance test |
| `docs/` | architecture and technical documentation |

## Quick start

```bash
lab/lab-up.sh          # 4 machines, etcd, Patroni cluster, repository, first backup, timers
tests/run-all.sh       # all six scenarios, about 7 minutes
```

Last full run: 6 scenarios, 57 assertions, 0 failures ([log](docs/test-run-2026-11-23.log)).

One measured trade-off: incremental backups need `summarize_wal = on`, which added 10 to 25 s to
most unplanned failovers in the lab and nothing to planned switchovers. The decision (2026-11-23)
is to keep incrementals. See [docs/TECHNICAL.md §10.6](docs/TECHNICAL.md) for the numbers and how
to reverse it, and the two CSV files in `docs/` for the raw data.

```bash
orb -m pgbackup sudo -u postgres pgbr check     # health of backups + WAL archive
orb -m pgbackup sudo -u postgres pgbr list      # backups in the repository
orb -m pg1 sudo -u postgres patronictl -c /etc/patroni/config.yml list
```

Lab versions: Ubuntu 24.04, PostgreSQL 17.12, Patroni 4.1.5, etcd 3.4.30. Credentials in
`lab/lab.env` are for this lab only.
