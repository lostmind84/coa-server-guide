# Rebuilding a lost production server

Disaster recovery runbook: production is gone (disk, host or provider lost) and a new Ubuntu 26.04 host replaces
it. Path A: the build server still has its recent backup sets ([backup.md](backup.md)). Path B: the build server is
gone too, and everything comes from the offsite bucket ([backup-bucket.md](backup-bucket.md)).

Status: path A run on 2026-09-27 (sets and release copied with rsync from a host holding them; 11 minutes from the
loss to `worldserver ready`, including one repeated database load). Path B run on 2026-09-28 against the real
bucket with only `rclone.conf` and the passphrase: 5.5 minutes from the loss to `worldserver ready`, without the
release rebuild (about 5 minutes, measured separately). Both times the account created after the last full set was
restored.

Keep outside production and the build server: this guide (it is on GitHub), the `rclone.conf` of the bucket and the
crypt passphrase (password manager).

## 1. Prepare the new host

Follow the first installation of [prod-server.md](prod-server.md): packages (add `python3`), service account `coa`,
`/opt/coa` layout, MySQL user `acore`, `~coa/.my.cnf`. **Do not import the repack dump.**

Copy the scripts from the guide into `/opt/coa`: `coa-deploy-release.sh`, `coa-backup.sh`,
`coa-restore-backup.sh`, `coa-fix-windows-hashes.sh`. Create `/opt/coa/restore`.

## 2A. Build server still there: copy from it

Allow the build user to write to the new host for the transfer (its normal shipping key, without `command=`
restriction). On the build server:

```bash
B=/srv/coa-build/backups
FULL=$(for d in $B/daily/*/ $B/predeploy/*/; do basename "$d" | tr -d '\n'; echo " ${d%/}"; done | sort | tail -n 1 | cut -d' ' -f2)
HOURLY=$(ls -1d $B/hourly/*/ | sort | tail -n 1); HOURLY=${HOURLY%/}
echo "$FULL"; echo "$HOURLY"; cat "$HOURLY/manifest.env"
. "$HOURLY/manifest.env"
coa-ship-release.sh "$RELEASE_ID" coa@new-prod.example        # release and its client data
rsync -a "$FULL" "$HOURLY" coa@new-prod.example:/opt/coa/restore/
```

If `releases/` no longer holds `RELEASE_ID`, rebuild it from `REVISION` (`coa-build-release.sh <REVISION>`) and ship
the new release; use the new id in step 4.

Measured: 3 s for the release and 11 s for the client data on a local network; count 5 GB against your real
bandwidth.

## 2B. Build server gone too: download from the bucket

On the new host, as `coa`: install rclone (`curl -fsSL https://rclone.org/install.sh | sudo bash`), put the
`rclone.conf` from the password manager in `~/.config/rclone/rclone.conf` (mode 600), and recreate the crypt remote
with the passphrase exactly as in backup-bucket.md (`[coa-backups]` section). Then:

```bash
for k in hourly daily predeploy; do echo "$k: $(rclone lsf --dirs-only coa-backups:$k/ | tr -d / | sort | tr '\n' ' ')"; done
FULL=$(for k in daily predeploy; do rclone lsf --dirs-only coa-backups:$k/ | tr -d / | sed "s#^#$k #"; done | sort -k2 | tail -n 1)
HOURLY=$(rclone lsf --dirs-only coa-backups:hourly/ | tr -d / | sort | tail -n 1)
set -- $FULL
rclone copy "coa-backups:$1/$2" "/opt/coa/restore/$2"
rclone copy "coa-backups:hourly/$HOURLY" "/opt/coa/restore/$HOURLY"
. "/opt/coa/restore/$HOURLY/manifest.env"; echo "$RELEASE_ID $REVISION $DATA_VERSION"
rclone copy "coa-backups:static/$DATA_VERSION" "/opt/coa/data/$DATA_VERSION"
```

A wrong passphrase shows garbled or no file names; nothing can be recovered without it. Measured: a 94 MB set
downloaded and decrypted in 12 s. The client data download from `static/` was not part of the test (the test host
got the same folder locally).

The release: set up a new build host ([build-server.md](build-server.md), one-time setup, with
`DATA_VERSION` set to the manifest's value) and run `coa-build-release.sh <REVISION>`, then
`coa-ship-release.sh latest coa@new-prod.example` (it finds the client data already there). Its release id differs
from `RELEASE_ID`; use the new id in step 4.

## 3. Load the databases (new host, as `coa`)

```bash
cd /opt/coa
./coa-restore-backup.sh restore/<FULL timestamp> restore/<HOURLY timestamp>
```

Give the hourly set only if it is newer than the full set; the script refuses otherwise
(`hourly set … is not newer than full set …`) and the full set alone is then the newest state. The script refuses
to run while a server is running, checks the checksums, loads every database of the full set (including
`acore_playerbots` when present), then `acore_auth` and `acore_characters` from the hourly set, extracts the live
configuration into `/opt/coa/etc` if it holds no file yet, and compares the account and character counts with the
manifest:

```
>> restoring all databases from restore/20260928T124930Z
>> extracting configuration from restore/20260928T124930Z
>> accounts: 2 (backup: 2), characters: 0 (backup: 0)
>> restored. Backup taken at 20260928T124930Z on coa-restore-poc, release 20260927-1154-47dd22f (47dd22ffe6d0…),
   client data main-20260919-b3717c137, realm address was 127.0.0.1:8085. Next: install release … and run …
```

Load time in the tests: 3 to 4 minutes, almost all of it `acore_world`. Do **not** run `coa-fix-windows-hashes.sh`:
the backed-up databases already carry the Linux hashes.

Check the restored configuration for anything tied to the old host (database password in the `*DatabaseInfo` lines
if the new MySQL user has a different one, paths if the layout changed).

## 4. Realm address and start

If the public address changed, update it before starting (and the DNS name if players use one):

```bash
mysql -e "UPDATE acore_auth.realmlist SET address = 'NEW_PUBLIC_IP_OR_DNS' WHERE id = 1;"
./coa-deploy-release.sh <release id>
```

The deploy script verifies the release, takes a pre-deploy set of the restored state, starts worldserver (which
applies any SQL update the world database lacks) and authserver. Check `(worldserver-daemon) ready...` and log in
with a known account.

## 5. Put the backup chain back

- In `/home/coa/.ssh/authorized_keys`: the build server's shipping key and its read-only `rrsync` line
  (backup.md, production setup). Remove any temporary key.
- Restore the `coa` crontab (backup.md).
- Build server: point `SOURCE` in `coa-backup-pull.conf` and the ship target at the new host, accept its new SSH host
  key, then run the pull and the push and check both `--status`.
- On a rebuilt build server, also restore `coa-backup-push.conf`, the `[coa-backups]` remote and `STATIC_PATHS`
  (backup-bucket.md).

## Last resort: only the repack dump and a recent hourly set

If no full set can be read but an hourly set can (player data only), rebuild the world from the repack:

```bash
cd /opt/coa
zcat restore/databases.sql.gz | mysql                        # repack dump: all three databases
./coa-fix-windows-hashes.sh releases/<id>/source             # Windows-made dump, before the first start
gunzip < restore/<hourly set>/databases.sql.gz | mysql       # current accounts and characters
tar -xzf restore/<hourly set>/etc.tar.gz -C /opt/coa         # if /opt/coa/etc is empty
./coa-deploy-release.sh <id>
```

Tested on 2026-09-27: 6 minutes, 419 SQL updates applied to the repack's world database. Lost on this path: any
change made to `acore_world` in game since the repack (GM-spawned creatures, edited NPCs).

## Monthly drill

Run path B on a scratch host (a VM or an `ubuntu:26.04` container is enough), skip step 5, compare the counts, then
throw the host away. It proves the passphrase, the keys and the bucket all still work. Note the time each step
took.
