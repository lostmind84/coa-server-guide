# Backup server: operation

The backup server (a storage VPS) pulls every backup set from production, verifies it, keeps the history described
in [backup.md](backup.md), and holds what is needed to rebuild production without the build server: the release in
use and its client data. When production is lost, it is the source for [restore.md](restore.md).

It never writes to production, and production cannot reach it.

Status: run in an Ubuntu 26.04 container on 2026-09-27 (pulls, verification, retention with backdated sets,
status, then a full restore from it). Cron and alerting were not run.

## Layout

```
/srv/coa-backup/
  hourly/<timestamp>/  daily/<timestamp>/  predeploy/<timestamp>/   verified backup sets
  unverified/<kind>-<timestamp>/        sets that failed verification (kept for inspection, never deleted)
  releases/<id>/                        every release referenced by a kept set (hard links between releases)
  data/<version>/                       client data referenced by a kept set
  LAST_PULL                             time of the last successful pull
/home/coabackup/
  coa-backup.conf                       puller configuration
  coa-server-guide/                     clone of this guide: scripts and procedures, needed during a restore
  repack/databases.sql.gz               repack dump (rescue path of restore.md)
```

Space: about 2.3 GB of database sets at the default retention on a fresh realm (48 hourly + ~40 daily/weekly +
5 pre-deploy sets of 94 MB), plus 1.3 GB for the first release and a few hundred MB per later release, plus 3.8 GB
per client data version. Plan for at least 20 GB and watch `df`.

## Setup

Ubuntu 26.04 (any Linux with bash, GNU coreutils, rsync and OpenSSH works):

```bash
sudo apt-get install -y rsync openssh-client git
sudo useradd -m -s /bin/bash coabackup
sudo mkdir -p /srv/coa-backup && sudo chown coabackup: /srv/coa-backup
sudo -iu coabackup
ssh-keygen -t ed25519 -N '' -C coa-backup-pull -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
git clone https://github.com/lostmind84/coa-server-guide.git ~/coa-server-guide
mkdir -p ~/bin && ln -s ~/coa-server-guide/scripts/coa-backup-pull.sh ~/bin/
```

On production, add the public key to `/home/coa/.ssh/authorized_keys` with the read-only restriction:

```
command="/usr/bin/rrsync -ro /opt/coa/",restrict ssh-ed25519 AAAA... coa-backup-pull
```

Back on the backup server, accept the host key once, then write the configuration:

```bash
ssh coa@prod.example true         # answers with an rrsync error: expected, the key only allows rsync
cat > ~/coa-backup.conf <<'EOF'
SOURCE=coa@prod.example
DEST=/srv/coa-backup
EOF
coa-backup-pull.sh ~/coa-backup.conf
```

Keep a copy of the repack dump for the rescue path:
`~/repack/databases.sql.gz` (from `CoA-Repack/Database/Clean/`).

### Settings (`coa-backup.conf`)

| Setting | Default | Meaning |
| --- | --- | --- |
| `SOURCE` | required | `user@host` of production (the rrsync key maps `backups/…` to `/opt/coa/backups/…`) |
| `DEST` | required | local backup root |
| `KINDS` | `hourly daily predeploy` | set kinds to pull |
| `LATEST_ONLY` | `0` | `1` pulls only the newest set of each kind (light copies) |
| `KEEP_HOURLY_HOURS` | `48` | hourly sets older than this are deleted |
| `KEEP_DAILY_DAYS` | `30` | every daily set is kept this long |
| `KEEP_WEEKLY_WEEKS` | `12` | after that, the newest daily set of each ISO week is kept this long |
| `KEEP_PREDEPLOY` | `5` | newest pre-deploy sets kept |
| `PULL_RELEASES` | `1` | pull the releases and client data referenced by kept sets, drop the others |
| `MAX_HOURLY_AGE_HOURS` | `2` | status fails when the newest hourly set is older |

### Schedule

```
15 * * * * $HOME/bin/coa-backup-pull.sh $HOME/coa-backup.conf > $HOME/coa-backup-pull.log 2>&1 || <alert command>
```

Production takes its hourly set at :05, so the pull at :15 gets it. Any failure (production unreachable, a set that
fails verification, newest hourly older than 2 hours) makes the script exit non-zero. Plug the alert command into
whatever you use: `MAILTO` in the crontab, a push notification, or a dead-man's-switch service pinged only on
success.

## Daily operation

Status at any time:

```bash
coa-backup-pull.sh ~/coa-backup.conf --status
```

```
hourly: newest 20260927T191636Z (0h old), 3 kept
daily: 1 kept, newest 20260927T191145Z
predeploy: 1 kept, newest 20260927T191351Z
releases: 20260927-1154-47dd22f
client data: main-20260919-b3717c137
```

What happens on each pull:

1. List the sets on production (`rsync --list-only`, `.partial` folders ignored) and copy the new ones to
   `<set>.partial`.
2. Verify: `sha256sum -c`, `gzip -t`, the dump ends with `-- Dump completed`, `etc.tar.gz` is readable. A good set is
   renamed; a bad one moves to `unverified/` and raises an alert.
3. Apply retention (measured with backdated sets: of 5 hourly aged 1–72 h, the three under 48 h stayed; of 121 daily
   sets over 120 days, 30 days plus one per week back to 12 weeks stayed; of 7 pre-deploy, 5 stayed).
4. Pull any release and client data version named in a kept set's `manifest.env`, with `--link-dest` on the newest
   release already here; drop releases and data versions no kept set needs. A release production has already
   deleted cannot be pulled: an alert says so, and it can be rebuilt from `REVISION` on the build server.

First pull in the test: 22 s (release 1.3 GB and client data 3.8 GB on a local network); later pulls copy only new
sets.

## Alerts and what to do

| Message | Meaning | Action |
| --- | --- | --- |
| `ALERT: newest hourly backup is older than 2h` | production cron stopped, production down, or pull failing | check `coa-backup-pull.log`, then `crontab -l` and `/opt/coa/backups/hourly` on production |
| `ALERT: <kind>/<set> failed verification` | truncated or corrupted copy | run the pull again; if it fails again, check the set on production (`sha256sum -c`) and disk space on both sides |
| `ALERT: release <id> could not be pulled` | production already deleted it | rebuild it on the build server (`coa-build-release.sh <REVISION from manifest.env>`) and keep it there |
| `rrsync error: … not allowed` | the key is used for something other than a read-only rsync | expected for `ssh` commands; for pulls, check the `command=` line on production |

Monthly: rebuild production on a scratch host with restore.md and compare counts with the manifest.
