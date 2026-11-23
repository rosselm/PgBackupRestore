# Rolling out backup and PITR on an existing production Patroni cluster

For a cluster that is already running (1 primary + 2 replicas under Patroni) and has no backup
tooling from this project yet. It adds a backup repository host and the pgbr scripts **without
rebuilding anything and without downtime**, apart from one planned switchover if `archive_mode`
is currently off.

Why the design looks the way it does: [ARCHITECTURE.md](ARCHITECTURE.md). How each piece works and
how to operate it afterwards: [TECHNICAL.md](TECHNICAL.md).

**How far this procedure is tested.** It was rehearsed twice against the lab, with the lab stripped
back to "a Patroni cluster nobody has set up backups for" and the application workload running
throughout (`lab/rehearse-rollout.sh`, results in §11). That proves the sequence, the installers
and the impact on writes for Ubuntu 24.04, PostgreSQL 17 and Patroni 4.1. It does not prove
anything about RHEL-family paths, SELinux, other PostgreSQL versions or a TLS-protected Patroni
API; §12 lists what is unverified. Rehearse on a non-production copy of the real cluster first.

---

## 1. Lab versus production: what goes where

| In this repository | Production? | What it is |
|---|---|---|
| `pgbr/repo/`, `pgbr/node/`, `pgbr/systemd/`, `pgbr/etc/` | **yes** | the tooling itself |
| `pgbr/install/preflight.sh` | **yes** | read-only discovery on a node |
| `pgbr/install/install-node.sh` | **yes** | installs the node side |
| `pgbr/install/install-repo.sh` | **yes** | installs the backup-host side |
| `docs/` | reference | this guide, architecture, technical documentation and runbooks |
| `lab/` | **never** | builds and manipulates the OrbStack lab; contains throwaway passwords |
| `tests/` | **never** | scenarios that kill primaries, drop tables and rewind the cluster |

Copy only the `pgbr/` directory to the servers. The examples below assume it was copied to
`/opt/pgbr-src` on every node and on the backup host.

The scripts in `tests/` refuse to run unless they find OrbStack, the lab's machines and the marker
file `/etc/pgbr/LAB` that only the lab build creates. That is a safety net, not a reason to keep
them anywhere near production.

## 2. What changes on production, and what each change costs

| Change | Where | Takes effect by | Impact on the application | Undo |
|---|---|---|---|---|
| pgbr scripts, config, dedicated SSH key | every node, files only | nothing runs yet | none | `install-node.sh uninstall` |
| database role `backup` | SQL on the primary | immediately | none | `drop owned by backup; drop role backup` |
| two `pg_hba` entries for `backup` | wherever `pg_hba` is managed | reload | none | remove, reload |
| `archive_command`, `archive_timeout`, `wal_keep_size`, `summarize_wal`, `wal_summary_keep_time`, `restore_command` | Patroni cluster-wide config | reload | none | set back, reload |
| `archive_mode = on` (only if it is `off` today) | Patroni cluster-wide config | **restart of every member** | one switchover: writes paused 4.2 s in the rehearsal, all connections dropped once | another rolling restart |
| backfill timer; optional `on_role_change` callback | every node | timer start; Patroni reload | none | disable timer; remove, reload |
| first backup, then the schedules | backup host | when started | read I/O on one replica | disable timers |

Two lasting effects to be aware of:

* `archive_timeout = 60` closes a WAL segment every minute on an idle primary. In the repository an
  empty segment compresses to about a kilobyte; on the nodes it means more segment files cycling
  through `pg_wal`. Raise it if a one-minute bound on archive lag is tighter than you need.
* `summarize_wal = on` (for incremental backups) lengthens most unplanned failovers by 10 to 25 s
  (TECHNICAL.md §10.6). That trade-off was decided in favour of incrementals; leave the two
  `summarize_wal` / `wal_summary_keep_time` settings out and set `PGBR_INCREMENTAL=0` to reverse it.

## 3. Before you start

**A backup host** that is not one of the database nodes:

* the PostgreSQL *server* package of the cluster's major version, installed but with no instance
  initialised or running (the binaries are needed for `pg_basebackup`, `pg_verifybackup`,
  `pg_combinebackup` and for restore drills). On Debian/Ubuntu set `create_main_cluster = false`
  in `/etc/postgresql-common/createcluster.conf` before installing;
* `curl`, `jq`, `zstd`, an SSH server;
* disk: fulls kept × database size, plus incrementals, plus the WAL of the retention window
  (compressed), plus **one more database size of scratch space** for restore drills, side restores
  and combining incrementals.

**Network flows to open**

| From | To | Port | Purpose |
|---|---|---|---|
| backup host | every node | 5432 | `pg_basebackup` (replication protocol) and a few SQL statements |
| backup host | every node | Patroni REST port (8008) | `GET /cluster`, to find a replica |
| every node | backup host | 22 | WAL push and fetch, backup fetch for an in-place restore |

**Decide**

* the cluster name pgbr uses: take the Patroni `scope`;
* retention (`PGBR_RETENTION_DAYS`, `PGBR_KEEP_FULL_MIN`) and the full-backup interval;
* `wal_keep_size`: how much WAL a promoted node can still push into the archive after a failover,
  so effectively how long a repository outage may last without leaving a gap. 1 GB in the lab;
* a password for the `backup` role;
* a window for the switchover, if Phase 5b applies.

## 4. Phase 0 — Discovery (read-only)

On **every** node:

```bash
sudo bash /opt/pgbr-src/install/preflight.sh | tee preflight-$(hostname -s).txt
```

It changes nothing. It prints the PostgreSQL version, directories, the current archive and recovery
settings, replication head-room, tablespaces, how Patroni is configured (callbacks, where `pg_hba`
lives, the cluster-wide settings), and ends with a section **"What this means for the rollout"**.
Act on that section before going further:

| Preflight says | Meaning |
|---|---|
| `archive_mode is OFF` | Phase 5b applies: rolling restart with one switchover |
| `archive_mode is already on` | no restart anywhere; skip Phase 5b |
| `archive_command is a placeholder` | typical Patroni default (`/bin/true`); safe to replace |
| `archive_command is ALREADY IN USE` | **stop.** Another tool archives WAL today. Replacing the command ends that tool's archive. Decide what happens to it and to its backups first, and keep its last backups until this design has its own verified full backup |
| `restore_command is already set` | it will be replaced; check nothing else relies on it |
| `N user tablespace(s)` | **stop.** Not supported by pgbr as built |
| `max_wal_senders` / `max_replication_slots` have no head-room | raise them first (restart) or a base backup cannot start |
| `full_page_writes is off` | turn it on first; backups from a replica are unsafe without it |
| `Patroni callbacks already exist` | leave them; see Phase 6 |
| `pg_hba is not in this node's Patroni file` | add the entries wherever it is managed (Phase 4) |
| `PostgreSQL … older than 17` | full backups only; see §12 |
| `SELinux is enforcing` | untested; see §12 |

The last line of the output gives the values `install-node.sh` will detect on that node.

## 5. Phase 1 — Backup host (no production impact)

```bash
sudo bash /opt/pgbr-src/install/install-repo.sh install \
     --cluster <scope> --pgbin <postgres bin dir> \
     --patroni "http://node1:8008 http://node2:8008 http://node3:8008"
```

This installs `/usr/local/bin/pgbr`, writes `/etc/pgbr/<scope>.conf`, creates the repository under
`/srv/pgbackup/<scope>` (change with `--repo-dir`) and installs the systemd units without enabling
them. Then:

```bash
sudoedit /etc/pgbr/<scope>.conf                 # retention, thresholds, alert command, max rate
sudo bash /opt/pgbr-src/install/install-repo.sh set-password --cluster <scope>   # prompts, no echo
```

If the Patroni REST API is served over TLS, use `https://` endpoints and set `PGBR_CURL_OPTS`
(for example `--cacert …`). pgbr only ever issues `GET /cluster`.

## 6. Phase 2 — Node side (no production impact)

On every node:

```bash
sudo bash /opt/pgbr-src/install/install-node.sh install --repo-host <backup host>
```

It detects the data and binary directories from the running server (override with `--pgdata`,
`--pgbin`, `--port`, `--socket-dir`, `--pg-user`), installs the five `pgbr-*` scripts, writes
`/etc/pgbr/node.conf`, creates a **dedicated** key `~postgres/.ssh/pgbr_ed25519` (it does not touch
existing keys) and installs the backfill timer disabled. PostgreSQL and Patroni are not touched.

## 7. Phase 3 — Trust between the nodes and the backup host

On the backup host, note its SSH host key fingerprint:

```bash
sudo bash /opt/pgbr-src/install/install-repo.sh host-fingerprint
```

For each node: print its public key,

```bash
sudo bash /opt/pgbr-src/install/install-node.sh show-key
```

register that line on the backup host (bound to the gateway of this cluster, nothing else),

```bash
echo '<the public key line>' | sudo bash /opt/pgbr-src/install/install-repo.sh add-node-key --cluster <scope>
```

then, back on the node, pin the backup host's key and verify:

```bash
sudo bash /opt/pgbr-src/install/install-node.sh trust-repo --fingerprint 'SHA256:…'
sudo bash /opt/pgbr-src/install/install-node.sh verify
```

`verify` must print that the node reaches the gateway *and nothing but the gateway*. Do not go on
until it does on all three nodes: from Phase 5 on, the primary depends on this channel to get rid
of its WAL.

## 8. Phase 4 — Database role and `pg_hba`

On the primary:

```sql
CREATE ROLE backup LOGIN REPLICATION PASSWORD '…';
GRANT pg_monitor, pg_checkpoint TO backup;          -- pg_checkpoint exists from PostgreSQL 15
GRANT EXECUTE ON FUNCTION pg_switch_wal() TO backup;
```

Two `pg_hba` entries, before any broader rule that would match first:

```
host  replication  backup  <backup host IP>/32  scram-sha-256
host  postgres     backup  <backup host IP>/32  scram-sha-256
```

Where they go depends on what the preflight reported: in `postgresql.pg_hba` of each node's
Patroni file followed by `systemctl reload patroni`, or in the cluster-wide configuration
(`patronictl edit-config`), or in whatever manages `pg_hba.conf` outside Patroni. Test from the
backup host, against every node:

```bash
sudo -u postgres psql "host=<node> user=backup dbname=postgres" -c "select 1"
```

The `replication` entry is proven by the first backup in Phase 7.

## 9. Phase 5 — Patroni settings

### 5a. Settings that only need a reload

On any node:

```bash
patronictl -c <patroni config> edit-config \
  -s "postgresql.parameters.archive_command=/usr/local/bin/pgbr-archive-push %p %f" \
  -s postgresql.parameters.archive_timeout=60 \
  -s postgresql.parameters.wal_keep_size=1GB \
  -s postgresql.parameters.summarize_wal=on \
  -s postgresql.parameters.wal_summary_keep_time=14d \
  -s "postgresql.recovery_conf.restore_command=/usr/local/bin/pgbr-archive-get %f %p"
```

Patroni shows the difference and asks for confirmation, then reloads every member within one
loop interval. Check:

```bash
patronictl -c <patroni config> list        # no member may show "Pending restart" at this point
```

* **If `archive_mode` is already `on`, archiving to the repository starts now**, with the next
  completed segment. Go straight to 5c.
* If `archive_mode` is `off`, nothing is archived yet, and PostgreSQL reports `archive_command` as
  `(disabled)` until 5b is done. That is normal.

### 5b. `archive_mode = on` — only if it is `off` today

```bash
patronictl -c <patroni config> edit-config -s postgresql.parameters.archive_mode=on
patronictl -c <patroni config> list        # all three members now show "Pending restart"
```

Then, one step at a time, waiting for `streaming` on both replicas after each:

```bash
patronictl -c <patroni config> restart <scope> <replica 1>
patronictl -c <patroni config> restart <scope> <replica 2>
patronictl -c <patroni config> switchover <scope> --leader <primary> --candidate <replica 1>
patronictl -c <patroni config> restart <scope> <former primary>
```

The switchover is the only moment the application notices: writes stop for a few seconds (4.2 s in
the rehearsal) and every connection is dropped once. The replica restarts interrupt reads on that
replica only. The new primary starts archiving as soon as it is promoted.

Restarting the primary in place instead of switching over is the alternative; it costs a full
PostgreSQL restart of the primary and was not rehearsed. The switchover is the route that was.

### 5c. Is WAL arriving?

On the primary:

```sql
select pg_switch_wal();
select last_archived_wal, last_archived_time, last_failed_wal, last_failed_time from pg_stat_archiver;
```

`last_archived_time` must be newer than `last_failed_time`. On the backup host,
`ls /srv/pgbackup/<scope>/wal` shows `.zst` files appearing.

**If archiving fails here**, WAL piles up in `pg_wal` on the primary. The PostgreSQL log shows the
reason (`pgbr-archive-push … FAILED to archive …`). Either fix it, or take the pressure off without
a restart while you investigate:

```bash
patronictl -c <patroni config> edit-config -s postgresql.parameters.archive_command=/bin/true
```

## 10. Phase 6 and 7 — Backfill, first backup, schedules

**Backfill timer**, on every node (it does nothing unless the node is primary):

```bash
sudo bash /opt/pgbr-src/install/install-node.sh enable-timer
```

**Promotion hook (optional).** It makes the backfill run at the moment of promotion instead of up
to five minutes later. In each node's Patroni file, then `systemctl reload patroni`:

```yaml
postgresql:
  callbacks:
    on_role_change: /usr/local/bin/pgbr-patroni-callback
```

If an `on_role_change` callback already exists (a virtual-IP script, for example), do not replace
it. Either rely on the timer alone, or add one line to the existing script:
`/usr/local/bin/pgbr-patroni-callback "$@"` (it detaches its work and always exits 0).

**First backup, restore drill, health check**, on the backup host:

```bash
sudo -u postgres pgbr -c <scope> backup --type full
sudo -u postgres pgbr -c <scope> restore-test --amcheck
sudo -u postgres pgbr -c <scope> check
```

* The backup is pulled from a replica and its duration scales with the database size; set
  `PGBR_MAX_RATE` beforehand if the replica's I/O needs protecting.
* The drill restores that backup plus all archived WAL into scratch space and runs `pg_amcheck`.
  It needs room for one copy of the database and is the first real proof that a restore works.
* `check` must end with every line `OK` and exit status 0.
* If the cluster is past timeline 1, the backup log contains
  `added 000000NN.history to the archive (taken from the backup)`. That is expected: PostgreSQL
  archives a timeline's history file only at the promotion that created it, which happened before
  this archive existed.
* The first backup may *start* at a WAL position older than the archive. That is fine: a backup
  carries the WAL of its own duration, and `check` verifies continuity from the backup's end.

**Schedules**, once the three commands above are clean:

```bash
sudo bash /opt/pgbr-src/install/install-repo.sh enable-timers --cluster <scope>
```

Daily backup with retention at 01:15, health check every 5 minutes, weekly re-verification and
weekly restore drill. Hook `pgbr check` (exit 0 / 1 / 2) into monitoring, or set `PGBR_ALERT_CMD`.

## 11. Acceptance on production, and what the rehearsal showed

**Safe to do on production**

* A side restore to a moment you can check, on the backup host, paused at the target
  (TECHNICAL.md §11.2). Compare a few known rows, then delete the instance. Production is not
  touched.
* The next planned switchover: afterwards `pgbr check` must still say `wal: continuous`, and the
  next backup must come from a replica of the new primary.
* Leave `pgbr check` running for a few days and look at the first scheduled backup, re-verification
  and restore drill in the journal.

**Never on production:** anything in `tests/` or `lab/`. The failover, in-place rewind and
measurement scenarios belong on a copy.

**Rehearsal results** (`lab/rehearse-rollout.sh`, 2026-11-23, heartbeat workload of one write per
second running throughout, cluster on timeline 62 and later):

| Starting point | PostgreSQL restarts | Write interruptions during the rollout | After the rollout |
|---|---|---|---|
| `archive_mode = on`, `archive_command = /bin/true` | none on any node | none (longest gap 1.1 s, the probe's own interval) | first full verified, restore drill with `pg_amcheck` clean, `check` all OK, point-in-time restore to a later moment exact (6516 rows) |
| `archive_mode = off` | each member once, rolling | one, 4.2 s, at the switchover | same checks pass (6874 rows); Patroni flagged all three members "Pending restart" as expected |

After the second rehearsal the six lab scenarios (failover with stranded WAL, backup source
promoted mid-backup, cluster rewinds, retention, drills) were run against the cluster exactly as
the rollout had left it: **6 scenarios, 57 assertions, 0 failures**
([test-run-after-rollout-2026-11-23.log](test-run-after-rollout-2026-11-23.log)). A cluster set up by this
procedure therefore behaves the same as the one the lab builds from scratch.

The rehearsal also found three defects, all fixed before this guide was written, which is the
argument for rehearsing on your own copy too:

* the node installer exited silently on a first install (it tried to read a config file that did
  not exist yet);
* an archive that begins on a cluster already past timeline 1 has no history file for the current
  timeline, which confused the health check; the first backup now supplies it;
* the health check demanded WAL from the first backup's *start*, which can predate the archive;
  it now checks from the backup's end, which is what a restore actually needs.

## 12. Rollback, and what is not verified

**Rollback**, most to least likely to be needed:

| To undo | Do | Restart? |
|---|---|---|
| WAL archiving to the repository | `edit-config -s postgresql.parameters.archive_command=/bin/true` | no |
| the schedules | `install-repo.sh disable-timers --cluster <scope>` | no |
| incremental backups / `summarize_wal` | `edit-config -s postgresql.parameters.summarize_wal=off`, `PGBR_INCREMENTAL=0` | no |
| `restore_command` on replicas | `edit-config -s postgresql.recovery_conf.restore_command=null` | no |
| the callback | remove it from each Patroni file, `systemctl reload patroni` | no |
| the node side | `install-node.sh uninstall [--purge-key]` (after the settings above no longer point at it) | no |
| the role | `drop owned by backup; drop role backup;` and the `pg_hba` entries | no |
| `archive_mode = on` itself | not needed for a rollback; turning it off again costs another rolling restart | yes |

**Not verified — check these on your own copy first**

* **RHEL-family systems.** Paths differ (`/usr/pgsql-17/bin`, `/var/lib/pgsql/17/data`, home
  `/var/lib/pgsql`); the installers detect or accept them but were only run on Ubuntu.
* **SELinux enforcing.** PostgreSQL will execute `ssh` from `archive_command`. Not tested; watch
  the audit log at Phase 5c.
* **PostgreSQL other than 17.** 14 to 16 should work with full backups only (`PGBR_INCREMENTAL=0`,
  no `summarize_wal`; restores copy the backup instead of using `pg_combinebackup`). That code path
  has never been executed. Before 14 it will not work as written.
* **Patroni REST API with TLS or authentication**, and `pg_hba` managed in the cluster-wide
  configuration or outside Patroni: described above, not exercised.
* **`synchronous_mode`.** The rolling restart and the switchover were rehearsed with asynchronous
  replication only.
* **Replacing an existing WAL archiver** (pgBackRest, Barman, WAL-G): deliberately a stop
  condition, not a procedure.
* **Size.** The lab database is tens of megabytes. Backup duration, restore-drill duration, scratch
  space and the effect of `--max-rate` on a replica are unknown for a real database.
* **Tablespaces** are not supported.
