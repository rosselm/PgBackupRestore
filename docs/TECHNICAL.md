# Backup, PITR and restore for a Patroni-managed PostgreSQL cluster — Technical documentation

How everything works, where it lives, how to operate it, and what was tested.
For the reasoning behind the design see [ARCHITECTURE.md](ARCHITECTURE.md).

Contents

1. [Lab inventory](#1-lab-inventory)
2. [What is installed where](#2-what-is-installed-where)
3. [Configuration](#3-configuration)
4. [The repository](#4-the-repository)
5. [WAL archiving in detail](#5-wal-archiving-in-detail)
6. [Base backups in detail](#6-base-backups-in-detail)
7. [Restore in detail](#7-restore-in-detail)
8. [Schedules, retention and monitoring](#8-schedules-retention-and-monitoring)
9. [Test scenarios and results](#9-test-scenarios-and-results)
10. [Things learned the hard way](#10-things-learned-the-hard-way)
11. [Runbooks](#11-runbooks)
12. [Operating the lab](#12-operating-the-lab)
13. [Porting to the customer environment](#13-porting-to-the-customer-environment)

---

## 1. Lab inventory

| Machine | Role | Software |
|---|---|---|
| `pg1`, `pg2`, `pg3` | PostgreSQL + Patroni + etcd member | PostgreSQL 17.12, Patroni 4.1.5, etcd 3.4.30 |
| `pgbackup` | backup repository, scheduler, restore/drill host, demo workload | PostgreSQL 17.12 binaries (no cluster), `pgbr` |

All four are OrbStack machines running Ubuntu 24.04 (arm64). Host names are pinned in
`/etc/hosts` by `lab/05-hosts.sh` because OrbStack's `*.orb.local` DNS did not answer from inside
the machines.

| Port | Where | Used by |
|---|---|---|
| 5432 | nodes | applications, replication, `pg_basebackup` from `pgbackup` |
| 8008 | nodes | Patroni REST API (`pgbr` reads `GET /cluster`) |
| 2379 / 2380 | nodes | etcd client / peer |
| 22 | `pgbackup` | WAL push/fetch and backup fetch from the nodes (forced command) |

Database roles: `postgres` (superuser, Patroni), `replicator` (replication), `rewind` (`pg_rewind`),
`backup` (`REPLICATION`, `pg_monitor`, `pg_checkpoint`, `EXECUTE` on `pg_switch_wal()`), `app`
(demo workload). Lab passwords are in `lab/lab.env`.

The demo database `demo` has a `heartbeat(id, ts, node, tli)` table. A service on `pgbackup`
inserts one row per second into whichever node is primary, recording the timeline it was written
on. Every PITR test is judged by counting those rows, so "recovered to the right moment" is a
number, not an impression.

## 2. What is installed where

### On every PostgreSQL node

| Path | Purpose |
|---|---|
| `/usr/local/bin/pgbr-archive-push` | `archive_command` |
| `/usr/local/bin/pgbr-archive-get` | `restore_command` (normal and `--strict`) |
| `/usr/local/bin/pgbr-wal-backfill` | pushes ancestor-timeline WAL missing from the archive |
| `/usr/local/bin/pgbr-patroni-callback` | Patroni `on_role_change` hook, starts the backfill |
| `/usr/local/bin/pgbr-node-restore` | in-place PITR of this node's data directory |
| `/usr/local/lib/pgbr/node-lib.sh` | shared: config loading, the SSH wrapper |
| `/etc/pgbr/node.conf` | repository host, `PGDATA`, binary directory |
| `/etc/systemd/system/pgbr-wal-backfill.{service,timer}` | backfill retry every 5 minutes |
| `/var/log/pgbr/backfill.log`, `pitr-postgres.log` | logs |
| `~postgres/.ssh/id_ed25519` | key accepted only by the repository gateway |
| `/etc/patroni/config.yml` | Patroni configuration |

### On the backup host

| Path | Purpose |
|---|---|
| `/usr/local/bin/pgbr` | the CLI: backup, list, verify, expire, restore, restore-test, check, gateway |
| `/etc/pgbr/<cluster>.conf` | one file per cluster (`pglab.conf`) |
| `/srv/pgbackup/<cluster>/` | the repository (§4) |
| `/etc/systemd/system/pgbr-*@.{service,timer}` | schedules (§8) |
| `~postgres/.pgpass` | password of the `backup` role |
| `~postgres/.ssh/authorized_keys` | node keys, each bound to `pgbr -c <cluster> gateway` |

Source of all of it: `pgbr/` in this project (`repo/`, `node/`, `systemd/`, `etc/`).
Everything on the backup host runs as the OS user `postgres`.

## 3. Configuration

### 3.1 Patroni: cluster-wide settings (stored in the DCS)

These are in `bootstrap.dcs` of `/etc/patroni/config.yml` and from then on live in etcd; change
them with `patronictl edit-config`. Because they are cluster-wide, every node archives the same
way the moment it becomes primary.

| Setting | Value | Why |
|---|---|---|
| `archive_mode` | `on` | only the primary archives (ARCHITECTURE §3.2) |
| `archive_command` | `/usr/local/bin/pgbr-archive-push %p %f` | |
| `archive_timeout` | `60` | an idle primary still closes a segment every minute: bounds how far the archive can lag |
| `wal_keep_size` | `1GB` | how much a promoted node can still backfill; size it to cover the longest repository outage you want to survive without a gap |
| `summarize_wal` | `on` | required for incremental `pg_basebackup`; adds 10–25 s to most unplanned failovers, see §10.6 |
| `wal_summary_keep_time` | `14d` | must exceed the interval between a backup and its incremental child |
| `wal_log_hints` | `on` | `pg_rewind` (data checksums are also on) |
| `recovery_conf.restore_command` | `/usr/local/bin/pgbr-archive-get %f %p` | replicas can catch up from the archive; a promoting node sees existing timeline IDs |
| `use_pg_rewind`, `use_slots` | `true` | |

### 3.2 Patroni: per-node settings

```yaml
postgresql:
  callbacks:
    on_role_change: /usr/local/bin/pgbr-patroni-callback
  remove_data_directory_on_rewind_failure: true
  remove_data_directory_on_diverged_timelines: true
  pg_hba:
    - host replication backup samenet scram-sha-256     # pg_basebackup from the backup host
```

The two `remove_data_directory_*` settings let a node that cannot be rewound re-clone itself. That
is convenient and it deletes data directories automatically; decide whether you want that.

### 3.3 `/etc/pgbr/node.conf`

```sh
PGBR_REPO_HOST=pgbackup
PGBR_REPO_USER=postgres
PGBR_PGDATA=/var/lib/postgresql/17/main
PGBR_PGBIN=/usr/lib/postgresql/17/bin
PGBR_PGPORT=5432
# optional: PGBR_SSH_KEY, PGBR_SSH_MUX=0, PGBR_SSH_CONNECT_TIMEOUT, PGBR_GET_RETRIES, PGBR_GET_RETRY_SLEEP
```

### 3.4 `/etc/pgbr/<cluster>.conf` on the backup host

Annotated template: `pgbr/etc/cluster.conf.example`. The settings that shape behaviour:

| Setting | Lab value | Meaning |
|---|---|---|
| `PGBR_PATRONI_ENDPOINTS` | all three `:8008` URLs | any one that answers is enough |
| `PGBR_BACKUP_FROM` | `prefer-replica` | `replica` \| `prefer-replica` \| `primary` |
| `PGBR_MAX_REPLICA_LAG_BYTES` | 64 MiB | replicas lagging more are skipped |
| `PGBR_MAX_RATE` | unset | `pg_basebackup --max-rate` |
| `PGBR_MANIFEST_CHECKSUMS` | `SHA256` | |
| `PGBR_INCREMENTAL` / `PGBR_FULL_INTERVAL_DAYS` | `1` / `7` | weekly full, incrementals in between |
| `PGBR_INCR_FALLBACK_FULL` | `1` | an incremental that cannot be taken becomes a full |
| `PGBR_INCR_PRIMARY_CHECKPOINT` | `1` | `CHECKPOINT` on the primary before an incremental from a replica |
| `PGBR_RETENTION_DAYS` / `PGBR_KEEP_FULL_MIN` | `7` / `2` | PITR window / floor |
| `PGBR_MAX_BACKUP_AGE_HOURS` | `26` | `check` threshold |
| `PGBR_MAX_ARCHIVE_AGE_SECONDS` | `600` | `check` threshold; keep it well above `archive_timeout` |
| `PGBR_ALERT_CMD` | unset | called as `<cmd> "<subject>"` with details on stdin |
| `PGBR_RESTORE_PORT` | `5499` | port for drills and default for side restores |
| `PGBR_RESTORE_EXTRA_CONF` | unset | file included into a side instance's config, e.g. `shared_preload_libraries` the WAL depends on |

## 4. The repository

```
/srv/pgbackup/pglab/
├── wal/                                   flat directory
│   ├── 0000000B0000000000000035.zst       WAL segment, zstd
│   ├── 000000090000000000000032.partial.zst   last segment of a timeline that ended in a promotion
│   ├── 0000000B.history                   timeline history, plain
│   └── .tmp/                              in-flight uploads
├── base/
│   ├── 20261123T144330F/                  full backup (…F) or incremental (…I); the ID is the UTC start time
│   │   ├── data/                          exactly what pg_basebackup wrote (plain format, WAL included)
│   │   ├── backup.info                    pgbr metadata
│   │   ├── pg_basebackup.log
│   │   └── pg_verifybackup.log
│   └── .inprogress-<id>/                  a running backup; renamed into place only after it verified
├── state/                                 system_id, locks, last-restore-test, wal-conflicts
├── log/                                   pgbr.log, restore-test.log, logs of failed attempts
└── scratch/                               side restores, drills, temporary combined backups
```

`backup.info` (plain `key=value`):

```
id=20261123T144346I            type=incr                parent=20261123T144330F
status=ok                      cluster=pglab            system_id=7711370960295306399
source_node=pg2                source_role=replica      pg_version=17.12
start_time=…                   stop_time=…              stop_epoch=…
start_lsn=0/35000BB8           start_wal=0000000B0000000000000035   start_tli=11
stop_lsn=0/35000C88            stop_tli=11              size_bytes=…      verified_at=…
```

* `start_lsn`/`start_wal`/`start_tli` come from `backup_label`; `stop_lsn`/`stop_tli` from the
  last entry of `WAL-Ranges` in `backup_manifest`.
* `stop_time` is the source server's clock read right *after* `pg_basebackup` returned: a slightly
  late, therefore safe, upper bound for the backup's consistency point. A backup is eligible for a
  time target only if `stop_epoch <= target`.
* `system_id` is compared with the repository's on every backup; a mismatch aborts, so a repository
  can never be fed by a different cluster by mistake.

## 5. WAL archiving in detail

### 5.1 Push (`archive_command`)

```
PostgreSQL archiver ──► pgbr-archive-push %p %f
                          sha256 + size of the local file
                          ssh postgres@pgbackup "wal-push <name> <sha256> <size>" < file
                                 │
                       pgbr gateway: gw_wal_push
                          1. name must look like a segment, .partial, .history or .backup file
                          2. read stdin to wal/.tmp/<name>.XXXXXX
                          3. size and sha256 must match what the node announced
                          4. a segment's size must be a power of two ≥ 1 MiB
                          5. zstd-compress (history/backup files stay plain), fsync
                          6. ln tmp → wal/<name>.zst      atomic; fails if the name exists
                             ├─ created: fsync directory, exit 0
                             └─ exists:  compare content
                                   ├─ identical: exit 0   (retry, or backfill racing the archiver)
                                   └─ different: record in state/wal-conflicts, exit 1
```

Any non-zero exit makes PostgreSQL keep the segment and retry. SSH connections are multiplexed
(`ControlMaster`, 120 s persistence) so a busy primary does not pay a handshake per segment.

### 5.2 Fetch (`restore_command`)

`pgbr-archive-get [--strict] %f %p` runs `ssh … "wal-get <name>"`, writes to a temporary file and
renames it into place.

| Gateway result | Normal mode (replicas) | `--strict` (PITR) |
|---|---|---|
| file delivered | exit 0 | exit 0 |
| not in the archive (gateway exit 44) | exit 1: "no more WAL here" | exit 1: recovery reached the end of the archive |
| anything else (SSH down, repository error) | exit 1: fall back to streaming | retry 10× every 6 s, then **exit 200**: PostgreSQL aborts recovery |

PostgreSQL treats any exit status above 125 from `restore_command` as fatal. That is what stops a
PITR from "finishing" early because the repository was unreachable for a moment.

### 5.3 Backfill after a promotion

`pgbr-wal-backfill` runs on the node that is primary:

1. Current timeline from `pg_walfile_name(pg_current_wal_lsn())`; nothing to do on timeline 1.
2. Read `pg_wal/<tli>.history`. Each line is an ancestor timeline and the LSN where it was left.
3. Candidates: files in `pg_wal` named for an ancestor timeline, with a segment number **lower than
   the segment containing that timeline's switch LSN**, and of exactly `wal_segment_size` bytes.
4. One call `wal-missing` returns which of those the repository does not have.
5. Each missing one is sent through the normal push path (so all the push checks apply).

Why the "lower than the switch segment" rule matters: the old-timeline file *at* the switch segment
is partial, and files with higher numbers under an old timeline's name are recycled leftovers.
Everything below the switch segment was received in full and is part of the new timeline's history.

Triggers: `pgbr-patroni-callback` (`on_role_change` to `primary`, runs detached with `--wait`
because Patroni kills callbacks that outlive the next one), and `pgbr-wal-backfill.timer` every
5 minutes on every node (exits immediately on a replica, silently when nothing is missing).

### 5.4 Continuity check

`pgbr check` computes, from the newest history file in the archive, the lineage
`(timeline, begin LSN, end LSN)…`. For every segment number between the start of the oldest usable
backup and the newest archived segment it derives the one file a recovery would read (the
highest timeline in the lineage that had begun by then) and tests that it exists. Missing files
are listed; the check goes critical.

## 6. Base backups in detail

`pgbr backup [--type auto|full|incr] [--from NODE]`

1. Lock (`state/backup.lock`): one backup or expire at a time.
2. Decide the type. `auto`: full if there is no usable full or the newest is older than
   `PGBR_FULL_INTERVAL_DAYS`; otherwise incremental on top of the newest usable backup.
3. `try_sources`, up to 6 attempts. Each attempt **re-reads `GET /cluster`**, builds the candidate
   list for the policy, and takes the first node not yet tried in this run. If none is eligible
   right now (a failover is settling) it waits 10 s and looks again.
4. Per attempt (`run_backup`):
   * compare the node's system identifier with the repository's;
   * incremental from a replica: `CHECKPOINT` on the primary, wait until the replica has replayed it;
   * `pg_basebackup -h <node> -U backup -D base/.inprogress-<id>/data -Fp -X stream -c fast
     --manifest-checksums=SHA256 [--incremental=<parent>/data/backup_manifest] [--max-rate=…]`;
   * `pg_verifybackup` on the result; failure discards the backup;
   * write `backup.info`, fsync, **rename** `.inprogress-<id>` to `<id>`.
   A backup therefore either exists complete and verified, or not at all.
5. If an incremental failed on every candidate and `PGBR_INCR_FALLBACK_FULL=1`: repeat as a full.
6. `pg_switch_wal()` on the primary, so the segment containing the backup's end reaches the archive
   without waiting for `archive_timeout`.
7. Print the backup ID on stdout (everything else goes to stderr and `log/pgbr.log`).

Exit status is non-zero, and `PGBR_ALERT_CMD` is called, if no backup could be produced.

## 7. Restore in detail

### 7.1 Choosing the backup

`select_backup` (used by side restores, drills, and through the gateway by node restores):

1. Target timeline: the given one, or `latest` = the highest timeline that has a history file in
   the archive (the same thing PostgreSQL's `recovery_target_timeline = 'latest'` resolves to).
2. Keep backups whose end point lies on that timeline's lineage: same timeline, or an ancestor
   left *after* the backup's stop LSN.
3. Keep those with `stop_epoch <=` target time (or `stop_lsn <=` target LSN).
4. Keep those whose chain back to a full is complete and `ok`.
5. Take the newest.

Target times must carry an explicit UTC offset (`2026-11-23T15:30:00+00:00`). Without one, the
backup host and the database could interpret the same string in different time zones.

### 7.2 Side restore (`pgbr restore`, on the backup host)

```
pgbr restore --target-dir DIR
     [--backup ID] [--target-time T | --target-lsn L | --target-name N | --immediate]
     [--target-timeline latest|N] [--action promote|pause|shutdown] [--port P] [--listen ADDR] [--start]
```

1. `pg_combinebackup <full> [<incr>…] -o DIR` (also used for a lone full; it validates manifests).
2. `prepare_side_instance` neutralises everything the backup inherited from its source node:
   * removes `standby.signal` (a backup from a replica contains it), creates `recovery.signal`;
   * moves `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` aside (`*.pgbr-orig`) and writes
     minimal ones: `archive_mode = off`, `listen_addresses` local, own port, the recovery target,
     `restore_command = 'pgbr -c <cluster> wal-fetch "%f" "%p"'`;
   * copies the five parameters hot standby requires to be at least as large as on the primary
     (`max_connections`, `max_worker_processes`, `max_wal_senders`, `max_prepared_transactions`,
     `max_locks_per_transaction`) and `track_commit_timestamp` from `pg_controldata`.
3. With `--start`: `pg_ctl start`, then wait until recovery has promoted, or paused when
   `--action pause` was asked.

`wal-fetch` is the local, strict equivalent of `pgbr-archive-get`: exit 1 only when the file is
genuinely absent, 200+ on any other error.

The side instance promotes onto a timeline of its own. Because `archive_mode` is off, nothing of
that ever reaches the real archive.

### 7.3 Restore drill (`pgbr restore-test [--backup ID] [--amcheck]`)

Newest usable backup → combine → recover through **all** archived WAL → promote → checks:
databases connectable, last replayed commit time (how far the archive reaches), optional
`PGBR_RESTORE_TEST_SQL`, optional `pg_amcheck --all --install-missing`. Result and duration go to
`state/last-restore-test` and `log/restore-test.log`; `check` alerts when the last success is too
old. The scratch instance is removed afterwards.

### 7.4 In-place node restore (`pgbr-node-restore`, on a node)

Used only as part of a whole-cluster PITR (§11.3). As `postgres`, with Patroni stopped:

1. Refuses to run if Patroni or PostgreSQL is active.
2. `backup-select` through the gateway; the repository chooses the backup.
3. Moves the current data directory to `…/main.pre-pitr.<timestamp>` (or deletes it with
   `--discard-old-pgdata`).
4. `backup-stream <id>` → `zstd -d` → `tar -x` into `PGDATA`. For an incremental the repository
   combines the chain in its scratch space first and streams the result.
5. Removes `standby.signal`, creates `recovery.signal`, and deletes the Patroni-written recovery
   lines from `postgresql.conf` (§10.3).
6. Starts PostgreSQL with all recovery settings **on the command line**, so nothing lingers in the
   files Patroni manages: `listen_addresses=''` (local socket only), strict `restore_command`, the
   target, `recovery_target_action=promote|pause`. `archive_mode` stays on: this *is* the real
   cluster continuing, its new timeline must be archived.
7. `--pause`: stops here with recovery paused and prints how to inspect, accept (`--resume`) or
   reject. Otherwise, or on `--resume`: promotion, `CHECKPOINT`, clean shutdown.

## 8. Schedules, retention and monitoring

### 8.1 Timers on the backup host (instance name = cluster)

| Unit | When | Runs |
|---|---|---|
| `pgbr-backup@pglab.timer` | daily 01:15 (+≤5 min jitter, catches up after downtime) | `pgbr backup --type auto`, then `pgbr expire` only if the backup succeeded |
| `pgbr-check@pglab.timer` | every 5 minutes | `pgbr check` (exit 1 = warnings, unit still "success"; exit 2 = unit failed) |
| `pgbr-verify@pglab.timer` | Saturday 03:00 | `pgbr verify --all`, idle I/O priority |
| `pgbr-restore-test@pglab.timer` | Sunday 04:00 | `pgbr restore-test --amcheck` |

On every node: `pgbr-wal-backfill.timer`, every 5 minutes.

### 8.2 Retention (`pgbr expire [--dry-run]`)

1. Anchor = the newest full backup that is already older than `PGBR_RETENTION_DAYS`. A restore to
   the start of the window would be built on it.
2. Never keep fewer than `PGBR_KEEP_FULL_MIN` fulls: the anchor is moved back if needed.
3. Delete every backup older than the anchor (their incrementals go with them, since chains are
   linear in time).
4. `pg_archivecleanup -x .zst -b wal/ <anchor's start segment>` removes older WAL on all timelines
   and obsolete `.backup` files. Timeline history files are never removed.

### 8.3 `pgbr check`

```
OK    patroni: leader=pg1 timeline=11 members=pg1:leader:running,pg2:replica:streaming,pg3:replica:streaming
OK    backup: newest is 20261123T144346I (incr from pg2), 0min old; 5 usable backup(s)
OK    timeline: backups only restorable with an explicit older --target-timeline: 20261123T143900I
OK    wal: continuous from backup 20261123T143813F to the newest archived segment on timeline 11
OK    wal: last segment archived 10s ago (0000000B0000000000000035.zst)
OK    archiver: healthy on the leader (0 waiting, 0 failures since stats reset)
OK    restore-test: last success 0h ago (backup 20261123T144034F)
```

| Line | Critical when | Warning when |
|---|---|---|
| patroni | no endpoint answers, or no running leader | |
| backup | none, or newest older than `PGBR_MAX_BACKUP_AGE_HOURS`; any backup marked `corrupt` | |
| wal continuity | any segment missing on the path from the oldest usable backup | |
| wal freshness | nothing archived for `PGBR_MAX_ARCHIVE_AGE_SECONDS` | |
| archiver | `pg_stat_archiver` shows the last attempt failed | more than 4 segments waiting |
| conflicts | a conflicting push was recorded in the last 24 h | |
| restore-test | last run failed | never run, or older than `PGBR_MAX_RESTORE_TEST_AGE_DAYS` |

Exit status 0 / 1 / 2, so it plugs into any Nagios-style monitoring; critical results also go
through `PGBR_ALERT_CMD`.

## 9. Test scenarios and results

All scenarios are scripts in `tests/`, run from the Mac against the live lab; `tests/run-all.sh`
runs them in order (about 7 minutes). All of this happened on 2026-11-23.

* The figures in the table are from the first passing run of each scenario, while the lab was being
  built (timelines 1 to 11).
* After the last code change the whole suite was run again in one uninterrupted pass:
  **6 scenarios, 57 assertions, 0 failures**, taking the cluster from timeline 12 to 18. The
  unedited output of that run is in [test-run-2026-11-23.log](test-run-2026-11-23.log).
* The first attempt at that final pass failed in scenario 2, and the cause was the test, not the
  cluster: it slept a fixed 15 seconds after the failover and counted old lines in the backfill
  log, while that particular promotion needed 24 seconds to accept writes (§10.6). The scenario
  now waits for the new primary to be writable and asserts that each stranded segment, by name, is
  in the archive and was pushed by the backfill.

| # | Scenario | What was proven | Result |
|---|---|---|---|
| 1 | `01-pitr-side-restore.sh` — a table is dropped | Side restore to a timestamp just before the `DROP`: table back with 1000 rows; heartbeat count equals the count at the target exactly (118), zero rows after it; side instance has `archive_mode=off`; production untouched; table copied back with `pg_dump`. | pass |
| 2 | `02-failover-wal-gap.sh` — primary dies holding unarchived WAL | 4 completed segments existed only on the nodes; primary killed with SIGKILL and powered off; new leader elected; hook backfilled all 4; `check` reports the archive continuous across the switch; incremental taken from the surviving replica on the new timeline (parent on timeline 1, child on timeline 4); three restores **from the pre-failover backup** hit the exact row count before the failover (580), inside the never-archived window (595) and after the failover (613, rows from timelines 1–4); old primary rejoined as a replica. | pass |
| 3 | `03-backup-during-switchover.sh` — backup source is promoted mid-backup | Rate-limited backup running from `pg1`; switchover to `pg1`; PostgreSQL failed that backup; `pgbr` re-read the topology and completed a verified full from `pg2`; no `.inprogress` directory left; exit status 0. | pass |
| 4 | `04-cluster-pitr.sh` — bad release, rewind the whole cluster | Cluster back at the chosen moment on all three nodes (957 rows each), nothing from after it on the old timeline, application writes resumed on the new timeline; replicas rejoined via `pg_rewind`; archive continuous along the new timeline; the backup taken on the abandoned branch is flagged; a side restore with `--target-timeline 7` still reaches the abandoned branch's damaged state (490 rows). | pass |
| 5 | `05-retention-and-drills.sh` | Dry run removes nothing; real run keeps exactly the anchor and newer, no WAL older than the anchor's start segment, history files kept; archive still continuous; all backups re-verify; a single flipped byte in a stored data file is caught and the backup marked `corrupt`; restore drill with `pg_amcheck` clean; a paused side restore shows exactly the target's data and promotes on resume. | pass |
| 6 | `06-cluster-pitr-two-phase.sh` — pause, inspect, reject, retry, accept | First target (too late) recovered and paused: the damage is visible, Patroni still down, nothing committed; rejected; second target paused: data intact (1149 rows); `--resume` promotes and the cluster is rebuilt around it. | pass |

Also checked by hand: a backup with `--from <leader>` (primary as source); an incremental whose
parent lies on an abandoned branch is refused by PostgreSQL (`manifest requires WAL from final
timeline 7 ending at 0/2B022180, but this server switched timelines at 0/2B001CF8`), which is what
triggers the fallback to a full.

The two measurement runs of §10.6 added 24 switchovers and 20 hard failovers (timelines 19 to 62).
Afterwards `pgbr check` still reported the archive continuous from a backup taken on timeline 14,
and a side restore **from the timeline-18 backup** to a moment on timeline 62 replayed across all
44 timeline switches and matched production to the row (3732 heartbeat rows). In those 20 hard
failovers, with the repository reachable, exactly one segment was left unarchived by a dying
primary; the promotion hook on the new primary pushed it (`backfilled 0000002C0000000000000096`).

**Not tested:** LSN / named-restore-point / `immediate` targets; `PGBR_BACKUP_FROM=replica` with no
replica available; behaviour with tablespaces; a full repository outage lasting longer than
`wal_keep_size`; `lab/lab-up.sh` as one uninterrupted run (its steps were run one by one while
building the lab); anything at realistic data volume.

## 10. Things learned the hard way

Each of these cost a failed run in the lab and shaped the result.

### 10.1 A crashed primary that comes back and is promoted again also loses its archive queue

The gap is usually described as "primary lost, standby promoted". The lab hit a second form: the
primary was killed with four segments queued, Patroni restarted it, it won the leader race again
(new timeline), and its `.ready` markers for the four old-timeline segments were gone. The archive
resumed on the new timeline with a four-segment hole behind it. `pgbr check` reported it as
critical; a backfill run closed it, because the segment files themselves were still in `pg_wal`.

### 10.2 A hook at promotion time is not enough

In that same incident the `on_role_change` hook did fire, but could not reach the repository
(the test had removed the node's key to create the backlog). The situation is realistic: if the
repository is unreachable, that is both why WAL is queuing *and* why the hook fails. Hence the
5-minute timer. The window for a successful retry is as long as the segments stay in `pg_wal`,
which is what `wal_keep_size` buys.

### 10.3 "multiple recovery targets specified" with a single target

A backup taken from a Patroni node contains Patroni's generated `postgresql.conf`, which sets
*every* `recovery_target_xxx = ''` explicitly. PostgreSQL's check treats assigning even an empty
value to a different target type as a second target once one is set, so starting with
`-c recovery_target_time=…` failed. `pgbr-node-restore` now deletes Patroni's recovery lines from
the restored file first; Patroni regenerates that file when it takes over. Side restores were never
affected because they get a new configuration file.

### 10.4 After an in-place PITR, the DCS configuration comes from the backup

`patronictl remove` deletes the cluster-wide configuration too. When Patroni adopts the recovered
node it re-creates the key from `patroni.dynamic.json` in the data directory: the configuration as
it was **when the backup was taken**. Anything changed since would be silently lost, so the runbook
saves `patronictl show-config` first and re-applies it once the key exists again (it appears a few
seconds after the leader does).

### 10.5 One in-place PITR advances the timeline by two

Recovery promotes onto timeline N+1. Patroni then starts the adopted data directory as a standby
first and promotes it when it wins the leader lock: N+2. Harmless, visible in the scenarios
(7 → 9, 9 → 11), and worth knowing before someone wonders where a timeline went.

### 10.6 `summarize_wal = on` lengthens unplanned failovers, not switchovers (measured)

Incremental backups need `summarize_wal = on`. During the scenarios some promotions took 14 to 24
seconds to accept writes, with this in the PostgreSQL log:

```
LOG:      received promote request
LOG:      selected new timeline ID: 12
WARNING:  still waiting for WAL summarization through 0/420001B8 after 10 seconds
DETAIL:   Summarization has reached 0/3E000788 on disk and 0/420001B8 in memory.
WARNING:  still waiting for WAL summarization through 0/420001B8 after 20 seconds
LOG:      database system is ready to accept connections          (24 s after the promote request)
```

That was then measured as an A/B: the same role changes with the setting on and off, on the idle
lab and under a steady write load (`pgbench`, 200 transactions per second). Scripts:
`tests/measure-promotion.sh` (planned switchovers) and `tests/measure-failover.sh` (primary killed
with SIGKILL and powered off). Raw data: [promotion-measurements-2026-11-23.csv](promotion-measurements-2026-11-23.csv),
[failover-measurements-2026-11-23.csv](failover-measurements-2026-11-23.csv).

*Promotion time* is "received promote request" to "ready to accept connections" in the PostgreSQL
log. *Write outage* is the longest gap between two rows of the 1-per-second heartbeat, i.e. what
an application sees, including Patroni's own part.

**Planned switchover (24 runs): no measurable cost.**

| `summarize_wal` | Load | Runs | Promotion time (min / median / max) | Waited for summarizer | Write outage (min / median / max) |
|---|---|---|---|---|---|
| on | idle | 6 | 0.1 / 0.6 / 0.8 s | 0 of 6 | 3.1 / 3.1 / 4.1 s |
| off | idle | 6 | 0.1 / 0.1 / 0.1 s | 0 of 6 | 2.1 / 2.6 / 3.1 s |
| on | pgbench | 6 | 0.1 / 0.2 / 0.4 s | 0 of 6 | 3.1 / 3.1 / 3.3 s |
| off | pgbench | 6 | 0.0 / 0.1 / 0.1 s | 0 of 6 | 2.1 / 2.1 / 3.1 s |

The outage differs by at most about a second, which is the resolution of the heartbeat probe. The
summarizer being far behind did not matter: under load it trailed the replay position by 40 to
84 MB and the promotion still took 0.1 to 0.4 s.

**Unplanned failover (20 runs): a real cost.**

| `summarize_wal` | Load | Runs | Promotion time (min / median / max) | Waited for summarizer | Write outage (min / median / max) |
|---|---|---|---|---|---|
| on | idle | 5 | 0.1 / 13.3 / 26.1 s | 4 of 5 | 34.7 / 46.9 / 60.1 s |
| off | idle | 5 | 0.1 / 0.1 / 0.1 s | 0 of 5 | 31.6 / 34.7 / 35.7 s |
| on | pgbench | 5 | 3.0 / 17.7 / 18.0 s | 4 of 5 | 26.4 / 53.0 / 53.2 s |
| off | pgbench | 5 | 0.1 / 0.1 / 0.3 s | 0 of 5 | 28.5 / 32.5 / 34.7 s |

With the setting off, every one of the 10 failovers promoted in 0.3 s or less and the write outage
was 28 to 36 s, almost all of it Patroni waiting out the leader lock (`ttl: 30`). With it on,
8 of 10 promotions waited for the summarizer, adding 10 to 26 s; the typical write outage went from
about 33 s to about 50 s, worst case 60 s.

What this does and does not establish:

* The effect is caused by the setting: it appears in 8 of 10 failovers with it on and in none of
  10 with it off, on the same nodes, minutes apart.
* It is specific to unplanned failover. The obvious difference is that no WAL arrives on the
  standby for the 25 to 35 seconds between the primary's death and the promotion, whereas in a
  switchover WAL flows until a moment before. That the summarizer sleeps longer when idle and is
  slow to notice the promotion is a plausible explanation; the lab did not prove it.
* Sample size is 5 per cell, on PostgreSQL 17.12, with a database of a few tens of megabytes. The
  size of the delay on the customer's system may differ; that it exists is not in doubt.

The choice this leaves:

| Option | Failover | Backups |
|---|---|---|
| Keep `summarize_wal = on` | unplanned failover takes roughly 10 to 25 s longer to accept writes, most of the time | weekly full + daily incrementals: least backup I/O and repository space |
| `summarize_wal = off`, `PGBR_INCREMENTAL=0` | no penalty | a full backup every day, from a replica: more I/O on that replica and more repository space; restores are, if anything, simpler |
| Summarize only on a dedicated backup replica (`summarize_wal = on` in that node's own `patroni.yml`, `nofailover: true`; `off` cluster-wide) | no penalty on the nodes that can be promoted | incrementals kept. **Not tested.** In a 1+2 cluster it leaves a single failover candidate, so it really wants a fourth node. |

Everything else in the design is independent of this choice.

**Decision (2026-11-23): keep incrementals.** `summarize_wal` stays `on` and the schedule stays
weekly full + daily incremental; the longer write outage on unplanned failover is accepted. To
reverse it later: `patronictl edit-config -s postgresql.parameters.summarize_wal=off` (a reload,
no restart) and `PGBR_INCREMENTAL=0` in `/etc/pgbr/<cluster>.conf`; the next scheduled backup is
then a full. Re-run `tests/measure-failover.sh` on the customer's hardware before treating the lab
figures as their failover time.

A consequence for anything scripted around failover either way: "Patroni says Leader" is not
"accepts writes". The test helpers wait for `pg_is_in_recovery() = false`.

### 10.7 Lab-only: `orb -m <machine>` boots a stopped machine

A status helper that looped over all nodes resurrected the "dead" primary seconds after the test
powered it off. The test helpers now skip machines a scenario has deliberately stopped. Nothing to
do with PostgreSQL, but it is the kind of thing that makes a failover test quietly test nothing.

## 11. Runbooks

Commands on the backup host are run as `postgres`. In the lab prefix them with
`orb -m pgbackup sudo -u postgres`; with a single configured cluster `-c pglab` can be omitted.

### 11.1 Day to day

```bash
pgbr check                      # health, exit 0/1/2
pgbr list                       # backups
pgbr backup                     # extra backup now (auto: full or incremental)
pgbr backup --type full         # force a full
pgbr backup --from pg3          # from a specific node
pgbr verify --all               # re-verify stored backups
pgbr restore-test --amcheck     # restore drill now
pgbr expire --dry-run           # what retention would remove
systemctl list-timers 'pgbr-*'  # schedules
journalctl -u 'pgbr-backup@*' -n 50
```

On a node:

```bash
patronictl -c /etc/patroni/config.yml list
psql -c "select last_archived_wal, last_archived_time, last_failed_wal, last_failed_time from pg_stat_archiver"
sudo -u postgres pgbr-wal-backfill      # run the backfill by hand (primary only)
tail /var/log/pgbr/backfill.log
```

### 11.2 Side restore: get data back without touching production

```bash
# 1. restore next to the repository, paused at the moment before the accident
pgbr restore --target-dir /srv/pgbackup/pglab/scratch/case-1234 \
     --target-time 2026-11-23T14:20:36+00:00 --action pause --port 5441 --start

# 2. look (read only while paused)
psql -h /var/run/postgresql -p 5441 -d demo

# 3. wrong moment? stop, delete the directory, repeat with another time.
#    right moment: copy what you need (works while paused, pg_dump only reads)
pg_dump -h /var/run/postgresql -p 5441 -d demo -t orders | psql -h <leader> -d demo

# 4. clean up
/usr/lib/postgresql/17/bin/pg_ctl -D /srv/pgbackup/pglab/scratch/case-1234 -m fast stop
rm -rf /srv/pgbackup/pglab/scratch/case-1234 /srv/pgbackup/pglab/scratch/case-1234.log
```

The time target needs WAL from *after* the target to be in the archive (PostgreSQL has to see a
later commit to know where to stop). For a very recent moment run `select pg_switch_wal()` on the
primary first, or wait `archive_timeout`.

### 11.3 In-place cluster PITR: every node goes back in time

Destructive. Do a side restore first to confirm the target. In the lab the whole sequence is
`lab/pitr-cluster.sh --target-time … [--pause]`; by hand:

```bash
# 1. save the cluster-wide configuration (any node)
patronictl -c /etc/patroni/config.yml show-config > /var/lib/postgresql/dcs-config.saved.yml

# 2. stop Patroni: replicas first, the leader last
systemctl stop patroni                      # on each replica, then on the leader

# 3. remove the cluster from the DCS (it asks for the cluster name and "Yes I am aware")
patronictl -c /etc/patroni/config.yml remove pglab

# 4. on the node that will become leader, as postgres:
pgbr-node-restore --target-time 2026-11-23T14:38:51+00:00 --pause
psql -d demo                                # inspect; read only
pgbr-node-restore --resume                  # accept: promote, checkpoint, clean shutdown
#   reject instead: pg_ctl -D $PGDATA -m fast stop
#                   pgbr-node-restore --target-time <other> --pause --discard-old-pgdata

# 5. start Patroni on that node; wait until it is Leader/running
systemctl start patroni
patronictl -c /etc/patroni/config.yml list

# 6. re-apply the saved configuration (the key reappears a few seconds after the leader)
patronictl -c /etc/patroni/config.yml edit-config --apply /var/lib/postgresql/dcs-config.saved.yml --force

# 7. start Patroni on the other nodes; they pg_rewind or re-clone onto the new timeline
systemctl start patroni

# 8. on the backup host: a new full backup, then confirm health
pgbr backup --type full
pgbr check

# 9. when satisfied, remove the kept copy on the restored node
rm -rf /var/lib/postgresql/17/main.pre-pitr.*
```

Notes:

* Step 4 keeps the old data directory next to the new one. Make sure the volume has room, or use
  `--discard-old-pgdata`.
* During step 4 PostgreSQL listens on the local socket only; applications cannot connect until
  Patroni is started in step 5.
* Backups taken after the target on the old timeline remain in the repository, flagged by `check`,
  until retention removes them. Use them with `--target-timeline <old>`.
* To recover onto a branch that is not the newest timeline, pass `--target-timeline N` in step 4.

### 11.4 After a failover

Nothing to do. To confirm:

```bash
pgbr check                              # "wal: continuous … on timeline N"
tail /var/log/pgbr/backfill.log         # on the new leader: "backfilled …" if anything was missing
```

If `check` reports missing segments and the backfill log shows nothing: the segments may still be
on another node (including the old primary once it is back). Run `pgbr-wal-backfill` on the leader.
If they are gone everywhere, PITR *across* that point is impossible from older backups: take a new
backup now (`pgbr backup --type full`); everything after it is recoverable again.

### 11.5 A WAL conflict was reported

`check` shows `wal: conflicting segment(s) were pushed`. Details are in
`/srv/pgbackup/<cluster>/state/wal-conflicts` (segment, pushing address, checksum). Two different
contents for the same segment name mean two nodes wrote WAL on the same timeline (split brain), or
a node of another cluster points at this repository. The repository kept the first version. Find
out which node pushed what before deleting anything.

### 11.6 Repository host lost

The cluster keeps running; the primary accumulates WAL in `pg_wal` (watch disk space, a full
`pg_wal` stops the primary). Rebuild the host (`lab/40-backup-host.sh`, `lab/45-ssh-trust.sh`,
`lab/60-enable-timers.sh` show what is needed), restore the repository from its off-site copy if
there is one, then `pgbr backup --type full`. Without an off-site copy the PITR history before the
new backup is gone, which is why the repository must be replicated in production.

## 12. Operating the lab

```bash
lab/lab-up.sh                 # build everything from nothing (idempotent)
tests/run-all.sh              # all six scenarios, about 7 minutes
tests/measure-promotion.sh    # A/B: summarize_wal on/off across planned switchovers (about 25 minutes)
tests/measure-failover.sh     # A/B: the same across hard failovers (about 30 minutes)
lab/pitr-cluster.sh --target-time <ISO8601> [--pause]
lab/05-hosts.sh               # re-pin host names if machine IPs changed after a restart
lab/lab-destroy.sh            # delete the four machines

orb -m pg1 sudo -u postgres patronictl -c /etc/patroni/config.yml list
orb -m pgbackup sudo -u postgres pgbr check
orb -m pgbackup sudo -u postgres pgbr list
```

Build order, if you want to run or adapt the steps one at a time:

| Script | Runs | Does |
|---|---|---|
| `00-create-vms.sh` | Mac | creates the machines |
| `05-hosts.sh` | Mac | pins host names in `/etc/hosts` everywhere |
| `10-packages.sh node\|backup` | in each machine | PGDG repository, PostgreSQL, Patroni, etcd, tools |
| `20-etcd.sh` | in each node | etcd member configuration |
| `30-patroni.sh` | in each node | pgbr node scripts, backfill timer, `patroni.yml`, SSH key |
| `40-backup-host.sh` | in `pgbackup` | `pgbr`, its config, the repository, unit files |
| `45-ssh-trust.sh` | Mac | node keys → gateway-only `authorized_keys`; verifies the restriction |
| `50-start-cluster.sh` | Mac | starts Patroni, creates the `backup` role and demo schema |
| `55-workload.sh` | Mac | heartbeat workload service |
| `60-enable-timers.sh` | Mac | enables the timers and runs backup + check once |

Versions and names are in `lab/lab.env`. The machines `debian` and `ubuntu` that already existed in
OrbStack are not part of the lab and were not touched.

## 13. Porting to the customer environment

What to copy: the `pgbr/` directory. What to adapt:

* **Paths.** `PGBR_PGBIN` and `PGBR_PGDATA`. On RHEL-family systems with PGDG packages these are
  `/usr/pgsql-17/bin` and `/var/lib/pgsql/17/data`, and `PGBR_SOCKET_DIR` is usually
  `/var/run/postgresql` as well; check `unix_socket_directories`.
* **PostgreSQL version.** 17+ for incrementals; otherwise `PGBR_INCREMENTAL=0` and remove
  `summarize_wal` / `wal_summary_keep_time` from the Patroni configuration.
* **Patroni configuration.** Add the settings of §3.1 with `patronictl edit-config` (changing
  `archive_mode` needs a restart of each member; Patroni flags it as pending) and the callback of
  §3.2 in each node's `patroni.yml` (reload).
* **`pg_hba.conf`** (through Patroni): a `replication` entry and a `postgres` database entry for
  the `backup` role from the backup host.
* **The `backup` role**: `CREATE ROLE backup LOGIN REPLICATION PASSWORD …; GRANT pg_monitor,
  pg_checkpoint TO backup; GRANT EXECUTE ON FUNCTION pg_switch_wal() TO backup;`
* **SSH**: one key per node for `postgres`, installed on the backup host with
  `restrict,command="/usr/local/bin/pgbr -c <cluster> gateway"`.
* **Sizing**: repository space ≈ fulls kept × database size + incrementals + WAL of the window
  (compressed) + scratch space of one database size for drills and combined restores;
  `wal_keep_size` on the nodes for the repository outage you want to ride out.
* **Tablespaces**, if used, need work first (ARCHITECTURE §7).

Before trusting it there: run the six scenarios against a non-production copy of the real topology.
They are the acceptance test.
