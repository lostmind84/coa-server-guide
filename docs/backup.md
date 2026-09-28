# Backup plan

What is backed up, how often, where it goes, and how the production host produces it. The backup server's own
operation is in [backup-server.md](backup-server.md); rebuilding a lost production host is in
[restore.md](restore.md). Host setup and release handling: [build-server.md](build-server.md),
[prod-server.md](prod-server.md).

Status: run end to end on 2026-09-27 with three Ubuntu 26.04 containers (production, backup server, replacement
production) plus the workstation as build server: backups, pulls, retention, a lost production host rebuilt from
the backup server, and the rescue path from the build server's light copy. Cron scheduling itself was not run
(the scripts were started by hand).

## Target

- **At most one hour of player progress lost** (RPO): player data is dumped every hour.
- **Production back within about 15 minutes** once a replacement host exists. Measured in the test after the
  packages were installed: 15 s to copy the release, client data and sets from the backup server, 4 min 11 s to load
  the databases, 30 s to deploy and start.
- A compromised or broken production host cannot destroy the backups: the backup server **pulls** them with a
  read-only key.

## What is backed up

| Data | Irreplaceable? | Where it is backed up |
| --- | --- | --- |
| `acore_auth` (accounts, realm address, bans) | yes | every set |
| `acore_characters` (characters, items, guilds, mail, banks) | yes | every set |
| `acore_world` (game content) | rebuildable: repack dump + the release's SQL updates; GM edits made in game are not | daily and pre-deploy sets |
| `acore_playerbots` (bot state and caches, only with [mod-playerbots](playerbots-prod.md)) | no: recreated empty at start, but a rollback needs it to match the release | daily and pre-deploy sets, when the database exists |
| `/opt/coa/etc` (live `.conf` files) | yes (hand-tuned) | every set |
| `deploy.log`, release in use, client data version | small, needed to rebuild | every set (`manifest.env`) |
| active release (`releases/<id>`) and client data (`data/<version>`) | rebuildable from the build server or from the commit | pulled by the backup server, once per release / version |
| logs, `releases/` history, old backups | no | not backed up |

Sizes measured in the test (a fresh realm): hourly set 32 KB, daily set 94 MB (`acore_world` is 99 % of it),
release 1.3 GB (later releases add only changed files), client data 3.8 GB (once per version). The hourly set grows
with the player base; `acore_world` barely changes.

## Backup sets

`scripts/coa-backup.sh` on production writes `/opt/coa/backups/<kind>/<UTC timestamp>/`:

```
databases.sql.gz   mysqldump --single-transaction (consistent, does not lock players out), --add-drop-database
etc.tar.gz         /opt/coa/etc
deploy.log         release history
manifest.env       KIND, CREATED_AT, HOST, DATABASES, RELEASE_ID, REVISION, DATA_VERSION, ACCOUNTS, CHARACTERS,
                   REALM_ADDRESS
SHA256SUMS
```

| Kind | Databases | When | Kept on production | Kept on the backup server | Kept on the build server |
| --- | --- | --- | --- | --- | --- |
| `hourly` | auth, characters | every hour at :05 | 24 | 48 hours | newest one each day, 7 days |
| `daily` | auth, characters, world | every day at 04:20 | 2 | 30 days, then one per week for 12 weeks | — |
| `predeploy` | auth, characters, world | by `coa-deploy-release.sh` before each deployment | 2 | last 5 | — |

A set is written to `<timestamp>.partial` and renamed only when the dump ends with `-- Dump completed` and the
checksums are written; the pullers ignore `.partial` folders. A lock prevents two backups from overlapping.

Why a restore can mix two sets: each database carries its own `updates` table. Restoring the newest daily or
pre-deploy set, then the newest hourly set on top, gives current player data with a world database the worldserver
brings up to date at startup if a release was deployed in between.

## Production setup

Package: `python3` is required in addition to the list in prod-server.md (`rrsync`, the read-only SSH wrapper, is a
Python script shipped with `rsync`).

As `coa`, with `coa-backup.sh` copied next to `coa-deploy-release.sh` in `/opt/coa` (the deploy script calls it):

```bash
crontab -e
```

```
5 * * * *  /opt/coa/coa-backup.sh hourly > /dev/null
20 4 * * * /opt/coa/coa-backup.sh daily > /dev/null
```

Errors go to stderr, so cron mails them if `MAILTO` is set. Check by hand once:

```bash
/opt/coa/coa-backup.sh hourly      # prints the set path
cat /opt/coa/backups/hourly/*/manifest.env | tail -11
```

Measured: hourly 0.5 s, daily 12 s on the test data.

Read-only access for the pullers, in `/home/coa/.ssh/authorized_keys` (one line per puller key):

```
command="/usr/bin/rrsync -ro /opt/coa/",restrict ssh-ed25519 AAAA... coa-backup-pull
command="/usr/bin/rrsync -ro /opt/coa/",restrict ssh-ed25519 AAAA... coa-build-light
```

With this key a puller can only read below `/opt/coa` (paths are relative: `backups/hourly/`, `releases/<id>/`,
`data/<version>/`). Tested: a shell command is refused (`SSH_ORIGINAL_COMMAND does not run rsync`) and so is a write
(`sending to read-only server is not allowed`). The build server's shipping key (`coa-ship-release.sh`) stays a
normal key and must be a different one.

## Light copy on the build server

Enough to rebuild production if the backup server is lost too: the newest hourly set (player data and
configuration), kept 7 days. The world database then comes from the repack dump plus the release's SQL updates
(see restore.md, rescue path). Size in the test: 104 KB per day.

`/srv/coa-build/coa-backup-light.conf`:

```bash
SOURCE=coa@prod.example
DEST=/srv/coa-build/backup-light
KINDS=hourly
LATEST_ONLY=1
KEEP_HOURLY_HOURS=168
PULL_RELEASES=0
MAX_HOURLY_AGE_HOURS=26
```

Cron (build user, with its own `rrsync` key on production):

```
30 5 * * * coa-backup-pull.sh /srv/coa-build/coa-backup-light.conf > /srv/coa-build/backup-light.log 2>&1
```

Also keep on the build server the repack dump (`CoA-Repack/Database/Clean/databases.sql.gz`, 90 MB) and its client
data folder, which the build already uses.

## Sensitive content

Sets contain account names, e-mail addresses and SRP password verifiers. They are created with mode `600`, the
folders belong to the service accounts, and they travel over SSH only. They are not encrypted at rest: encrypt them
(for example with `age`) before any copy leaves your own machines.

## Checking that it works

- Every pull verifies each new set (checksums, `gzip -t`, `-- Dump completed`, readable `etc.tar.gz`) and prints a
  status; it exits non-zero when the newest hourly set is older than `MAX_HOURLY_AGE_HOURS` or a set failed
  verification. See backup-server.md for alerting.
- Once a month, rebuild production on a scratch host with restore.md and compare the account and character counts
  with the manifest. A backup that was never restored is not a backup.
