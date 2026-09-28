# Rebuilding a lost production server

Disaster recovery runbook: production is gone (disk, host or provider lost) and a new Ubuntu 26.04 host replaces
it. Normal path: everything comes from the backup server ([backup-server.md](backup-server.md)). Rescue path: the
backup server is gone too, and the build server's light copy is used.

Status: both paths run on 2026-09-27 in Ubuntu 26.04 containers. Normal path, from production loss to the new
worldserver ready: 11 minutes including one repeated database load; without it, about 7 minutes after the packages
were installed. Rescue path: 6 minutes. The account created after the last daily set was present both times.

Keep this page available outside production: the guide is cloned on the backup server
(`~coabackup/coa-server-guide`).

## Normal path

### 1. Prepare the new host

Follow the first installation of [prod-server.md](prod-server.md): packages (add `python3`), service account `coa`,
`/opt/coa` layout, MySQL user `acore`, `~coa/.my.cnf`. **Do not import the repack dump.**

Copy the scripts from the guide into `/opt/coa`: `coa-deploy-release.sh`, `coa-backup.sh`,
`coa-restore-backup.sh`, `coa-fix-windows-hashes.sh`.

Allow the backup server to write to the new host for the transfer: add `~coabackup/.ssh/id_ed25519.pub` to
`/home/coa/.ssh/authorized_keys` **without** any `command=` restriction (removed again in step 6).

### 2. Pick the sets (backup server)

```bash
sudo -iu coabackup
B=/srv/coa-backup
FULL=$(for d in $B/daily/*/ $B/predeploy/*/; do basename "$d" | tr -d '\n'; echo " ${d%/}"; done | sort | tail -n 1 | cut -d' ' -f2)
HOURLY=$(ls -1d $B/hourly/*/ | sort | tail -n 1); HOURLY=${HOURLY%/}
echo "$FULL"; echo "$HOURLY"
cat "$HOURLY/manifest.env"
```

`FULL` is the newest set holding `acore_world` (daily or pre-deploy), `HOURLY` the newest hourly set. Use `HOURLY`
only if it is newer than `FULL` (the restore script checks). The manifest gives the release, the client data
version, the counts to expect and the old realm address.

### 3. Transfer (backup server to the new host)

```bash
. "$HOURLY/manifest.env"
NEW=coa@new-prod.example
rsync -a $B/releases/$RELEASE_ID/ $NEW:/opt/coa/releases/$RELEASE_ID/
rsync -a $B/data/$DATA_VERSION/ $NEW:/opt/coa/data/$DATA_VERSION/
ssh -n $NEW mkdir -p /opt/coa/restore
rsync -a "$FULL" "$HOURLY" $NEW:/opt/coa/restore/
```

Measured: 3 s for the release and 11 s for the client data on a local network; count the 5 GB against your real
bandwidth. The release folder keeps its `.complete` marker and checksums; the deploy script verifies them.

If the release is missing on the backup server, rebuild it on the build server from `REVISION`
(`coa-build-release.sh <REVISION>`) and ship it with `coa-ship-release.sh`; the new release id differs, use it
in step 5.

### 4. Load the databases (new host, as `coa`)

```bash
cd /opt/coa
./coa-restore-backup.sh restore/<FULL timestamp> restore/<HOURLY timestamp>
```

The script refuses to run while a server is running, checks the checksums, loads all three databases from the full
set, then `acore_auth` and `acore_characters` from the hourly set, extracts the live configuration into
`/opt/coa/etc` if it holds no file yet, and compares the account and character counts with the manifest:

```
>> restoring all databases from restore/20260927T191351Z
>> restoring acore_auth and acore_characters from restore/20260927T191636Z
>> extracting configuration from restore/20260927T191636Z
>> accounts: 2 (backup: 2), characters: 0 (backup: 0)
>> restored. Backup taken at 20260927T191636Z on coa-prod-poc, release 20260927-1154-47dd22f (47dd22ffe6d0…),
   client data main-20260919-b3717c137, realm address was 127.0.0.1:8085. Next: install release … and run …
```

Load time in the test: about 4 minutes, almost all of it `acore_world`. Do **not** run `coa-fix-windows-hashes.sh`
on this path: the backed-up databases already carry the Linux hashes.

Check the restored configuration for anything tied to the old host (database password in the
`*DatabaseInfo` lines if the new MySQL user has a different one, paths if the layout changed).

### 5. Realm address and start

If the public address changed, update it before starting (and the DNS name if players use one):

```bash
mysql -e "UPDATE acore_auth.realmlist SET address = 'NEW_PUBLIC_IP_OR_DNS' WHERE id = 1;"
./coa-deploy-release.sh <RELEASE_ID>
```

The deploy script verifies the release, takes a pre-deploy set of the restored state, starts worldserver (which
applies any SQL update the world database lacks) and authserver. Check `(worldserver-daemon) ready...` and log in
with a known account.

### 6. Put the backup chain back

- Remove the unrestricted backup-server key from `/home/coa/.ssh/authorized_keys` and add the two read-only
  `rrsync` lines (backup server and build server, see backup.md), plus the build server's shipping key.
- Restore the `coa` crontab (backup.md, production setup).
- Point `SOURCE` in `coa-backup.conf` (backup server) and `coa-backup-light.conf` (build server) at the new host,
  and accept its new SSH host key on both.
- Run `coa-backup.sh hourly` on the new host, then a pull on the backup server, and check `--status`.
- Update the build server's ship target.

## Rescue path: backup server lost too

Sources: the build server's light copy (newest hourly set, 7 days kept), the repack dump, and a release built from
the revision in the light copy's manifest.

1. Prepare the new host as in step 1.
2. On the build server: read `/srv/coa-build/backup-light/hourly/<newest>/manifest.env`. If `releases/` still holds
   `RELEASE_ID`, ship it; otherwise `coa-build-release.sh <REVISION>` then ship the new release. Copy the light set
   and the repack dump to `/opt/coa/restore/` on the new host.
3. On the new host, as `coa`, servers stopped:

   ```bash
   cd /opt/coa
   (cd restore/<hourly set> && sha256sum --quiet -c SHA256SUMS)
   zcat restore/databases.sql.gz | mysql                        # repack dump: all three databases
   ./coa-fix-windows-hashes.sh releases/<id>/source             # Windows-made dump, before the first start
   gunzip < restore/<hourly set>/databases.sql.gz | mysql       # current accounts and characters
   tar -xzf restore/<hourly set>/etc.tar.gz -C /opt/coa         # if /opt/coa/etc is empty
   ```

4. Realm address, then `./coa-deploy-release.sh <id>`: worldserver brings the repack's world database up to the
   release (419 SQL updates applied in the test). Then step 6.

What is lost on this path: up to 24 hours of player data (the light copy is daily), and any change made to
`acore_world` in game since the repack (GM-spawned creatures, edited NPCs).

## Monthly drill

Run the normal path on a scratch host (a VM or an `ubuntu:26.04` container is enough), skip step 6, compare the
counts, then throw the host away. Note the time each step took; if loading the databases grows past what you can
accept, that is the moment to revisit the plan.
