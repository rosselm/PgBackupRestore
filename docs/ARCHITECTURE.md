# Backup, PITR and restore for a Patroni-managed PostgreSQL cluster — Architecture

Native PostgreSQL tools only: `pg_basebackup`, `pg_verifybackup`, `pg_combinebackup`,
`pg_archivecleanup`, `pg_amcheck`, plus `archive_command` / `restore_command`.
A thin layer of shell (`pgbr`) orchestrates them and makes them safe under Patroni.

This document explains **what was built and why**. How each piece works in detail, the runbooks
and the test evidence are in [TECHNICAL.md](TECHNICAL.md). How to add it to an existing production
cluster, step by step, is in [PRODUCTION-ROLLOUT.md](PRODUCTION-ROLLOUT.md).

| | |
|---|---|
| Lab platform | 4 OrbStack machines on macOS (Ubuntu 24.04, arm64) |
| PostgreSQL | 17.12 (PGDG packages) |
| HA | Patroni 4.1.5, etcd 3.4.30 (3 members, co-located with PostgreSQL in the lab) |
| Topology | 1 primary + 2 streaming replicas (`pg1`, `pg2`, `pg3`), 1 backup repository host (`pgbackup`) |
| Status | Built and exercised end to end; six failure/recovery scenarios pass (see TECHNICAL.md §9) |

---

## 1. Goals

1. **Point-in-time recovery** to any moment inside a retention window, to the transaction.
2. **Scheduled base backups, taken from a replica**, so the primary carries no backup I/O.
3. **Every backup verified** when taken, re-verified periodically, and **proven restorable** by an
   automated restore drill.
4. **Correct under Patroni**: failover, switchover, promotion and node rebuilds must not break
   backups, must not leave holes in the WAL archive, and must not need a human to repoint anything.
5. Nothing but tools that ship with PostgreSQL, so there is no third-party backup product to
   license, patch or get approved.

## 2. The shape of the solution

```
                          applications
                               │  libpq multi-host, target_session_attrs=read-write
        ┌──────────────────────┼───────────────────────┐
   ┌────▼─────┐          ┌─────▼────┐            ┌─────▼────┐
   │   pg1    │◄────────►│   pg2    │◄──────────►│   pg3    │   streaming replication
   │ Postgres │          │ Postgres │            │ Postgres │
   │ Patroni  │          │ Patroni  │            │ Patroni  │   REST API :8008
   │ etcd     │          │ etcd     │            │ etcd     │   DCS quorum
   └────┬─────┘          └────┬─────┘            └────┬─────┘
        │                     │                       │
        │  (A) WAL push / WAL fetch / backup fetch    │        (B) pg_basebackup  :5432 replication
        │      SSH, forced command, one direction     │        (C) topology       :8008 GET /cluster
        └─────────────────────┬───────────────────────┘        (D) a little SQL   :5432
                              │                                         ▲
                        ┌─────▼─────────────────────────────────────────┴──┐
                        │                    pgbackup                      │
                        │  repository   wal/   base/   state/   log/       │
                        │  pgbr CLI + systemd timers (backup, check,       │
                        │  verify, restore drill)                          │
                        │  scratch space for side restores and drills      │
                        └──────────────────────────────────────────────────┘
```

Two independent data streams end up in one repository:

* **WAL, continuously, pushed by the cluster.** Every node carries the same `archive_command`;
  whichever node is primary ships each completed 16 MB segment over a restricted SSH channel (A).
* **Base backups, on a schedule, pulled by the backup host.** `pgbackup` asks Patroni who is who
  (C), picks a healthy replica and runs `pg_basebackup` against it over the replication
  protocol (B).

A restore is always *one base backup + the WAL that follows it*.

## 3. Design decisions

### 3.1 The backup host pulls; the nodes do not schedule anything

Under Patroni no node has a fixed role, so "run the backup from cron on the replica" has no stable
answer: the replica you picked may be the primary tomorrow, or gone. The schedule therefore lives
in exactly one place, the backup host, and the source is chosen at run time from Patroni's REST
API (`GET /cluster`):

* replicas in state `streaming`, lag below a threshold, not tagged `nobackup: true`, least lag first;
* the primary only as a fallback (`prefer-replica`), or never (`replica`), or always (`primary`).

If the chosen source changes role or dies mid-backup, PostgreSQL itself invalidates that backup
and `pgbr` re-reads the topology and tries another node. Tested: scenario 3.

**Why from a replica at all.** A base backup reads every data file once. On the primary that
competes with production for I/O and page cache; on a replica it does not. A backup from a standby
is fully supported by `pg_basebackup` (it needs `full_page_writes = on` on the primary, the
default). The one real cost is for *incremental* backups from a standby, see 3.4.

### 3.2 WAL archiving: `archive_mode = on` plus a backfill, not `archive_mode = always`

This is the decision that matters most for Patroni, so the reasoning is spelled out.

With `archive_mode = on` only the primary archives. That leaves a well-known hole:

> The primary completes segments N..N+k, its archiver has not shipped them yet (repository
> unreachable, slow link, or it simply dies in that second), and the node is lost. The standby that
> gets promoted *has* those segments, but as a standby it marked them "done" on arrival and will
> never archive them. The archive now ends at N-1 and resumes on the new timeline: a hole exactly
> where any later PITR that crosses the failover has to pass.

The lab reproduced this twice, including a variant that is easy to miss: the *same* node crashing,
being restarted by Patroni and promoted again also loses its queue of unarchived segments.

Three ways to close the hole were considered:

| Option | Verdict |
|---|---|
| `archive_mode = always` (every node archives everything into the shared archive) | Rejected. When a standby follows a timeline switch mid-segment, the WAL receiver hands the archiver the *partial* old-timeline segment under its *full* name (this is from reading the PostgreSQL source, it was not reproduced in the lab). Against a shared archive that either races with, or blocks, the real segment. It also triples archive traffic, and pgBackRest, for comparison, does not support this mode at all. |
| `pg_receivewal` streaming from the leader into the repository | Good, and the only way to get the archive's RPO near zero. Kept as an optional addition (§8) because it adds a second WAL path, a permanent replication slot and its own failover handling. |
| **Backfill from the promoted node** | **Chosen.** The promoted node still has the segments in `pg_wal` (kept by `wal_keep_size`). A hook pushes every *complete* segment of an *ancestor* timeline that lies strictly *before* the switch point and is not in the repository yet. |

The backfill is safe by construction: it never touches the segment in which the switch happened
(PostgreSQL archives that one itself as `.partial`), it only handles byte-complete segments, and
the repository refuses any file that differs from what it already holds under that name.

It runs from two triggers, and both are needed:

* Patroni's `on_role_change` callback, immediately at promotion;
* a 5-minute systemd timer on every node (a no-op unless the node is primary). The repository
  being unreachable is a likely *cause* of the backlog, and then the hook cannot reach it either.
  The lab hit exactly that; the retry closed the gap.

`pgbr check` independently walks the timeline history and reports any missing segment between the
oldest retained backup and the newest archived segment, so a hole is an alert, not a surprise at
restore time.

### 3.3 One restricted channel between the nodes and the repository

The `postgres` user on each node has an SSH key that, on the repository host, is bound to a forced
command (`restrict,command="pgbr -c <cluster> gateway"`). Through it a node can:

`wal-push`, `wal-get`, `wal-missing`, `backup-select`, `backup-stream`, `backup-list`

and nothing else: no shell, no forwarding, no other cluster's repository. The gateway parses the
request without `eval` and validates every argument against a strict pattern.

The WAL push protocol is deliberately strict, because a silently truncated segment is worse than a
missing one:

* the node sends name, size and SHA-256; the repository rejects a stream that does not match;
* the file is written to a temporary name, fsynced, then hard-linked into place (atomic, cannot
  overwrite);
* a re-push of identical content succeeds (so retries and the backfill are idempotent);
* a push of *different* content under an existing name fails loudly and is recorded. Two nodes
  producing different WAL for the same timeline means split brain or a foreign cluster.

A side benefit of giving replicas a `restore_command`: a promoting node probes the archive for
existing timeline history files, so it can never pick a timeline ID that was already used.

### 3.4 Base backup format: plain, self-contained, verified, optionally incremental

* **Plain format** (`-Fp`), one directory per backup. It is what `pg_combinebackup` needs for
  incrementals and what `pg_verifybackup` checks completely on PostgreSQL 17.
* **`-X stream`**: the WAL generated during the backup is inside the backup. Each backup is
  restorable to its own end point even if the WAL archive were lost entirely.
* **`--manifest-checksums=SHA256`**: per-file checksums in `backup_manifest`.
* **Incremental backups** (PostgreSQL 17+, `summarize_wal = on`): `--type auto` takes a full when
  the newest full is older than `PGBR_FULL_INTERVAL_DAYS`, otherwise an incremental on top of the
  newest backup. Restore synthesises a full with `pg_combinebackup`.

**Incrementals have a price at unplanned failover.** This was measured as an A/B in the lab
(TECHNICAL.md §10.6): 24 planned switchovers and 20 hard failovers, with `summarize_wal` on and
off, idle and under a write load.

* Planned switchover: no measurable difference. Every promotion took under a second either way.
* Unplanned failover: with the setting on, 8 of 10 promotions waited for the WAL summarizer and
  took 10 to 26 s to accept writes; with it off, all 10 took 0.3 s or less. The write outage seen
  by an application went from about 33 s to about 50 s (worst case 60 s).

So there is a choice between incremental backups and a shorter unplanned failover. **The decision
for this design (2026-11-23) is to keep incrementals** and accept the longer write outage. It is
reversible at any time: with `summarize_wal = off` and `PGBR_INCREMENTAL=0` the design takes a full
backup every day instead; nothing else changes. A third option, summarizing only on a dedicated non-promotable backup
replica, would keep both but is untested and wants a fourth node. The numbers come from a small lab
database; the size of the delay may differ on the real system, its existence should not.

Two more Patroni-specific points about incrementals:

* A standby can only start an incremental from a restartpoint newer than its parent, and it can
  only create restartpoints at checkpoints it has replayed. `pgbr` therefore issues a `CHECKPOINT`
  on the primary and waits for the replica to replay it before an incremental from a replica.
* The parent may have been taken from a *different node* and on a *different timeline* (tested:
  parent on timeline 1, child on timeline 4 from another node). PostgreSQL checks the lineage
  itself and refuses when the parent lies on an abandoned branch; `pgbr` then falls back to a full.

### 3.5 Verification in three layers

| Layer | When | What it proves |
|---|---|---|
| `pg_verifybackup` | immediately after every backup; a backup that fails is discarded | every file matches the manifest, the WAL inside the backup parses |
| `pg_verifybackup` again | weekly on everything in the repository | the stored copy has not rotted; a failing backup is marked `corrupt` and excluded from restores |
| Restore drill (`pgbr restore-test --amcheck`) | weekly | the newest backup *and* the WAL archive actually produce a running database; `pg_amcheck` finds no heap/index corruption |

Only the third layer tests what you are really paying for.

### 3.6 Two kinds of restore, deliberately different

**Side restore** — the default answer to "we lost data". The backup is rebuilt on the backup host
as an isolated instance, replayed to the target and optionally paused there. Production is not
touched; the missing rows or objects are copied back with `pg_dump`/`COPY`. The instance gets a
freshly generated configuration with `archive_mode = off`: a restored copy must never write into
the real WAL archive or try to follow the real primary.

**In-place cluster PITR** — the whole cluster goes back in time. This is destructive and has to be
done *with* Patroni, not around it:

1. stop Patroni everywhere, remove the cluster's state from the DCS (it describes a future that is
   being abandoned, and Patroni would refuse leadership to a node that is "behind" it);
2. restore and recover **one** node with PostgreSQL alone, reachable only through its local socket,
   optionally pausing at the target so the data can be inspected before anything is committed;
3. start Patroni there: it adopts the data directory and becomes leader;
4. start Patroni on the others: they `pg_rewind` onto the new timeline (or re-clone);
5. take a new full backup.

### 3.7 Timelines are first-class

Every promotion and every PITR starts a new timeline. After a PITR the old timeline does not
disappear: its WAL stays in the archive as a branch. `pgbr` reasons about this explicitly:

* a backup is offered for a restore only if it lies on the lineage of the target timeline;
* backups on an abandoned branch are kept and flagged, and remain reachable on purpose with
  `--target-timeline N` (tested: scenario 4, "we went back too far, we need something from after");
* retention removes WAL by segment number across all timelines and never removes history files.

### 3.8 Recovery must fail closed

`restore_command` exit codes decide whether recovery continues, ends, or aborts. Treating "the
repository is unreachable" as "there is no more WAL" would end a PITR early and promote a database
that is silently missing transactions. So there are two modes:

* replicas (Patroni's `restore_command`): any failure means "not found". A standby must be able to
  start and stream even when the repository is down.
* PITR (`--strict`): transport errors are retried, then the command exits with a code above 125,
  which makes PostgreSQL abort recovery instead of finishing it.

## 4. How Patroni events are handled

| Event | What happens | Evidence |
|---|---|---|
| Normal operation | primary archives each segment (at the latest `archive_timeout` = 60 s after the first write); daily backup from the least-lagged replica | scenario 1 |
| Unplanned failover | new primary archives `.partial` + history file and continues; hook + timer backfill what the old primary never archived; next backup is taken from a remaining replica | scenario 2 |
| Crashed primary restarts and is promoted again | same backfill path | observed during testing, TECHNICAL.md §10 |
| Switchover | same as failover, nothing unarchived in practice | scenario 3 |
| Backup source promoted or lost mid-backup | PostgreSQL rejects the backup; `pgbr` re-reads the topology and uses another node; no partial backup is kept | scenario 3 |
| No replica available | `prefer-replica`: backup from the primary; `replica`: fails and alerts | policy, primary path exercised manually |
| Replica re-clone / reinit | no effect; backups never depend on a particular node | by design |
| Replica falls behind what streaming can serve | fetches WAL from the archive through `restore_command` | by design |
| Repository host down | primary keeps WAL and retries; replicas unaffected; backups and checks alert; no HA impact | by design; partly observed |
| In-place PITR | §3.6; replicas rejoin by `pg_rewind` | scenarios 4 and 6 |
| Incremental whose parent is on an abandoned branch | PostgreSQL refuses, `pgbr` takes a full | verified manually |

## 5. Recovery objectives

**RPO.** A single node failing loses nothing from the archive's point of view: the survivors hold
the WAL and the backfill ships it. If the *whole cluster* is lost at once, the archive is behind by
at most the current, not yet completed segment: bounded by `archive_timeout` (60 s in the lab).
Closing that last minute needs streaming archiving (§8).

**Failover time** is Patroni's business, with one interaction: `summarize_wal` adds roughly 10 to
25 s to most unplanned failovers (§3.4).

**RTO.** Restore time is the copy of the base backup plus WAL replay since that backup. The lab
database is tiny, so its timings (seconds) say nothing about production; measure with the weekly
restore drill, which records its duration. Daily incrementals keep the replay distance short;
`PGBR_FULL_INTERVAL_DAYS` trades repository size against the cost of combining a longer chain.

**Retention.** `PGBR_RETENTION_DAYS` is a PITR window: the newest full backup older than the window
is kept together with everything after it, and WAL older than that backup's start is removed.
`PGBR_KEEP_FULL_MIN` is a floor that applies regardless.

## 6. Security model

* Nodes → repository: SSH key restricted to the gateway (§3.3).
* Repository → nodes: a database role `backup` with `REPLICATION`, `pg_monitor`, `pg_checkpoint`
  and `EXECUTE` on `pg_switch_wal()`. No superuser, no OS access to the nodes.
* Patroni REST: read-only `GET /cluster`.
* The repository contains a full copy of the data, unencrypted. Protect the host and its storage
  accordingly (§7).

## 7. What is lab-grade and must change for production

| Lab | Production |
|---|---|
| etcd co-located on the PostgreSQL nodes, no TLS, no auth | separate DCS (or at least TLS + auth) |
| passwords in `lab.env` and in `patroni.yml` | secrets management |
| `pg_hba.conf` uses `samenet` | explicit addresses |
| Patroni REST and replication without TLS | TLS |
| one repository host, one disk | the repository is a single point of failure for *backups*: replicate it off-site (storage replication, `rsync`, object storage sync) and monitor that copy |
| repository unencrypted, uncompressed base backups | encrypted and/or compressing filesystem (LUKS, ZFS, VDO); the WAL archive is already zstd-compressed |
| alerts go to the journal | set `PGBR_ALERT_CMD`, or scrape `pgbr check` (exit 0/1/2) from your monitoring |
| OrbStack machines (shared kernel, not full VMs) | real VMs; behaviour of PostgreSQL/Patroni is the same, I/O characteristics are not |
| asynchronous replication | consider `synchronous_mode` if zero data loss on failover is required; it is independent of this design |

Known functional limits of the tooling as built:

* **Tablespaces** are not handled (plain-format backups would need `--tablespace-mapping`).
* **PostgreSQL 17 or newer** is assumed for incrementals; on older versions set `PGBR_INCREMENTAL=0`.
* Backups are not parallel; `pg_basebackup` is single-stream. Very large databases restore faster
  from storage snapshots or a parallel tool.
* Only time targets, "end of archive" and pause/promote were exercised in the scenarios. LSN,
  named restore point and `immediate` targets are implemented but not covered by a test.

## 8. Options not built

* **Streaming WAL archiving with `pg_receivewal`** (native): a service on the backup host streams
  from the current leader through a Patroni *permanent* physical slot. Brings the archive RPO from
  "one segment" to near zero and makes the backfill a second line of defence. Needs care at
  timeline switches when the old primary was ahead of the new one.
* **Replica creation from the repository**: Patroni's `create_replica_methods` can call a script
  that restores from `pgbackup` instead of cloning the primary. Useful for large databases.
* **pgBackRest or Barman**: both solve this problem space (parallelism, compression, encryption,
  object storage, retention) and both integrate with Patroni. They were out of scope by
  requirement; if the native-tools constraint is ever lifted they are the first thing to evaluate.
  What this design gives in exchange is that every moving part is either a PostgreSQL binary or a
  few hundred lines of readable shell.
