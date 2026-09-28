# Backup plan

What is backed up, how often and where it goes. Rebuilding a lost production host is in [restore.md](restore.md);
the offsite bucket is set up in [backup-bucket.md](backup-bucket.md). Host setup and releases:
[build-server.md](build-server.md), [prod-server.md](prod-server.md).

```
production ──rsync over SSH, read-only key──> build server ──rclone crypt (S3)──> offsite bucket
 coa-backup.sh (cron)                          coa-backup-pull.sh, then            object lock (GOVERNANCE),
 /opt/coa/backups                              coa-backup-push.sh (cron)           lifecycle rules expire old sets
                                               keeps 48 h of hourly, 7 days of daily
```

Production never holds the bucket credentials, and the build server can only read production.

Status: run end to end on 2026-09-27/28. Production and build server were Ubuntu 26.04 and 24.04 containers; the
bucket was the real buckets.ninja bucket (test sets under a `_test/` prefix with 15-minute locks, deleted
afterwards). Tested: backup sets, pulls, local retention, encrypted upload with lock, refused deletion, a lost
production host rebuilt from the build server, and production **and** build server lost, rebuilt from the bucket
alone. Not observed yet: the bucket's lifecycle rules actually expiring objects (they need days), cron runs.

## Target

- **At most one hour of player progress lost** (RPO): player data is dumped every hour and leaves production ten
  minutes later.
- **Back online in minutes** once a replacement host with the packages exists. Measured with production and build
  server both gone: 5.5 minutes from the loss to `worldserver ready` (bucket download 12 s, database load 3 min),
  plus a release rebuild (about 5 minutes) since the build server is gone too.

## What is backed up

| Data | Irreplaceable? | Where it is backed up |
| --- | --- | --- |
| `acore_auth` (accounts, realm address, bans) | yes | every set |
| `acore_characters` (characters, items, guilds, mail, banks) | yes | every set |
| `acore_world` (game content) | rebuildable: repack dump + the release's SQL updates; GM edits made in game are not | daily, weekly and pre-deploy sets |
| `acore_playerbots` (bot state and caches, only with [mod-playerbots](playerbots-prod.md)) | no: recreated empty at start, but a rollback needs it to match the release | daily, weekly and pre-deploy sets, when the database exists |
| `/opt/coa/etc` (live `.conf` files) | yes (hand-tuned) | every set |
| `deploy.log`, release in use, client data version | small, needed to rebuild | every set (`manifest.env`) |
| releases | rebuildable from the commit in `manifest.env` (`REVISION`) | build server only |
| client data, repack dump | not rebuildable, rarely change | build server, and once in the bucket (`static/`) |
| logs, old releases | no | not backed up |

Sizes measured on a fresh realm: hourly set 32 KB, daily set 94 MB (`acore_world` is 99 % of it), client data
3.8 GB. The hourly set grows with the player base; `acore_world` barely changes.

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

| Kind | Databases | When | Production keeps | Build server keeps | Bucket keeps (lock = expiry) |
| --- | --- | --- | --- | --- | --- |
| `hourly` | auth, characters | every hour at :05 | 24 | 48 hours | 2 days |
| `daily` | auth, characters, world (+ playerbots) | every day at 04:20 | 2 | 7 days | 30 days |
| `weekly` | Sunday's daily set, copied by the push | Sundays | — | — | 84 days (12 weeks) |
| `predeploy` | auth, characters, world (+ playerbots) | by `coa-deploy-release.sh` before each deployment | 2 | 3 | 90 days |

A set is written to `<timestamp>.partial` and renamed only when the dump ends with `-- Dump completed` and the
checksums are written; the pull ignores `.partial` folders. A lock prevents two backups from overlapping.

Why a restore can mix two sets: each database carries its own `updates` table. Restoring the newest daily or
pre-deploy set, then a newer hourly set on top, gives current player data with a world database the worldserver
brings up to date at startup if a release was deployed in between.

## Production setup

`python3` is required in addition to the packages of prod-server.md (`rrsync`, the read-only SSH wrapper shipped
with `rsync`, is a Python script).

As `coa`, with `coa-backup.sh` next to `coa-deploy-release.sh` in `/opt/coa` (the deploy script calls it):

```
crontab -e
5 * * * *  /opt/coa/coa-backup.sh hourly > /dev/null
20 4 * * * /opt/coa/coa-backup.sh daily > /dev/null
```

Errors go to stderr, so cron mails them if `MAILTO` is set. Check by hand once:

```bash
/opt/coa/coa-backup.sh hourly      # prints the set path
cat /opt/coa/backups/hourly/*/manifest.env | tail -11
```

Measured: hourly 0.5 s, daily 12 s on the test data.

Read-only access for the build server, one line in `/home/coa/.ssh/authorized_keys` (a key used only for this, not
the shipping key of `coa-ship-release.sh`):

```
command="/usr/bin/rrsync -ro /opt/coa/",restrict ssh-ed25519 AAAA... coa-build-backup
```

Paths seen through this key are relative to `/opt/coa` (`backups/hourly/…`). Tested: a shell command is refused
(`SSH_ORIGINAL_COMMAND does not run rsync`) and so is a write (`sending to read-only server is not allowed`).

## Build server setup

Pull configuration, `/srv/coa-build/coa-backup-pull.conf`:

```bash
SOURCE=coa@prod.example
DEST=/srv/coa-build/backups
KEEP_HOURLY_HOURS=48
KEEP_DAILY_DAYS=7
KEEP_WEEKLY_WEEKS=0
KEEP_PREDEPLOY=3
PULL_RELEASES=0
```

`coa-backup-pull.sh` verifies each new set (checksums, `gzip -t`, `-- Dump completed`, readable `etc.tar.gz`),
applies the local retention and prints a status; a set that fails verification goes to `unverified/`. Local space:
about 1 GB (7 daily sets, 3 pre-deploy sets, 48 hourly sets).

The upload is described in [backup-bucket.md](backup-bucket.md). Both run from one cron line, ten minutes after the
production backup:

```
15 * * * * coa-backup-pull.sh /srv/coa-build/coa-backup-pull.conf && coa-backup-push.sh /srv/coa-build/coa-backup-push.conf
```

Keep on the build server, outside the rotation: the client data folder of the version in use and the repack dump
(`CoA-Repack/Database/Clean/databases.sql.gz`). Both are also uploaded once to the bucket (`STATIC_PATHS`).

### Pull settings (`coa-backup-pull.sh`)

| Setting | Default | Meaning |
| --- | --- | --- |
| `SOURCE` | required | `user@host` of production |
| `DEST` | required | local backup root |
| `KINDS` | `hourly daily predeploy` | set kinds to pull |
| `LATEST_ONLY` | `0` | `1` pulls only the newest set of each kind |
| `KEEP_HOURLY_HOURS` | `48` | hourly sets older than this are deleted |
| `KEEP_DAILY_DAYS` | `30` | every daily set is kept this long |
| `KEEP_WEEKLY_WEEKS` | `12` | after that, the newest daily set of each ISO week is kept this long (`0`: none) |
| `KEEP_PREDEPLOY` | `5` | newest pre-deploy sets kept |
| `PULL_RELEASES` | `1` | also pull the releases and client data named by kept sets (`0` on the build server, which has them) |
| `MAX_HOURLY_AGE_HOURS` | `2` | status fails when the newest hourly set is older |

Measured with backdated sets: of 5 hourly sets aged 1 to 72 h, the three under 48 h stayed; of 121 daily sets over
120 days, 30 days plus one per week back to 12 weeks stayed; of 7 pre-deploy sets, 5 stayed.

## Sensitive content

Sets contain account names, e-mail addresses and SRP password verifiers. They are created with mode `600`, travel
over SSH, and are encrypted by `rclone crypt` before they leave the build server: the bucket provider only sees
ciphertext and encrypted file names.

## Checking that it works

- `coa-backup-pull.sh <conf> --status` and `coa-backup-push.sh <conf> --status` on the build server; both exit
  non-zero when the newest hourly set is older than 2 hours, and the push also on any failed upload. Plug the cron
  line into your alerting (`MAILTO`, a push notification, or a dead-man's-switch pinged only on success).
- Once a month, run the bucket path of [restore.md](restore.md) on a scratch host and compare the counts with the
  manifest. A backup that was never restored is not a backup.
