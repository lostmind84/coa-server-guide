# Production server: install and update CoA from build-server releases

The production host runs the game. It never compiles anything: it receives releases from the build server
([build-server.md](build-server.md)) through rsync, and an admin deploys them with `coa-deploy-release.sh`. Database
updates are applied by worldserver itself at startup, from the SQL files shipped in each release. Nobody imports
update files by hand. Running bots (mod-playerbots): [playerbots-prod.md](playerbots-prod.md).

Status: run end to end on 2026-09-27 in an Ubuntu 26.04 container holding only the runtime packages below: first
installation, first deployment (revision `b3717c137`), then an update to `47dd22ffe` that applied the new SQL
updates, and rollbacks with database restore. Not tested: systemd services, a public realm address, firewall rules.

## Layout

```
/opt/coa/
  releases/<id>/       received releases (bin/, etc/*.dist, source/, RELEASE.md, release.env, SHA256SUMS, .complete)
  current -> releases/<id>                     active release: binaries and SourceDirectory
  etc/                 live worldserver.conf, authserver.conf, modules/*.conf (kept across releases)
  data/<version>/      client data (dbc, maps, vmaps, mmaps, Cameras)
  data/current -> <version>                    DataDir
  logs/  backups/  deploy.log
  coa-deploy-release.sh  coa-fix-windows-hashes.sh
```

The binaries look for their configuration in `/opt/coa/etc` (compiled in by the build server).

## First installation

### Packages (Ubuntu 26.04)

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends mysql-server mysql-client screen rsync less openssh-server python3 \
  libboost-atomic1.90.0 libboost-chrono1.90.0 libboost-container1.90.0 libboost-date-time1.90.0 \
  libboost-filesystem1.90.0 libboost-iostreams1.90.0 libboost-program-options1.90.0 libboost-random1.90.0 \
  libboost-regex1.90.0 libboost-thread1.90.0 libmysqlclient24 libreadline8t64 libssl3t64 libncurses6
sudo systemctl enable --now mysql
```

This list comes from `ldd` on the binaries; the deploy script checks again with `ldd` before each deployment and
stops if a library is missing. `mysql-client` is required at runtime: worldserver runs `mysql` to apply updates.
`python3` is needed by `rrsync`, the read-only access used by the backup pullers ([backup.md](backup.md)).

### Service account

```bash
sudo useradd -m -s /bin/bash coa
sudo mkdir -p /opt/coa/{releases,data,etc/modules,logs,backups}
sudo chown -R coa:coa /opt/coa
```

Add the build server's public key to `/home/coa/.ssh/authorized_keys`.

### Database

```bash
sudo mysql <<'SQL'
CREATE USER 'acore'@'localhost' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON acore_auth.*       TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_characters.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_world.*      TO 'acore'@'localhost';
SQL

zcat CoA-Repack/Database/Clean/databases.sql.gz | sudo mysql
```

The dump drops and recreates the three databases: never run it on a live server. Import time in the test: 3 to
5 minutes.

Credentials for the scripts (`coa` user, used by `mysqldump` and `mysql`):

```bash
sudo -iu coa sh -c 'printf "[client]\nhost=127.0.0.1\nuser=acore\npassword=CHANGE_ME\n" > ~/.my.cnf; chmod 600 ~/.my.cnf'
```

### First release

Ask the build server to ship a release (`coa-ship-release.sh latest coa@this-host`). Then, as `coa`:

```bash
sudo -iu coa
ID=<release id>
R=/opt/coa/releases/$ID
cp /path/to/scripts/{coa-deploy-release.sh,coa-backup.sh,coa-fix-windows-hashes.sh} /opt/coa/
```

**Record the Linux hashes of the Windows-made dump** (once, before the first worldserver start):

```bash
/opt/coa/coa-fix-windows-hashes.sh $R/source
```

Test output with the `b3717c137` release:

```
acore_world: rev_1787754600000000000.sql 563E4DD -> 9AB2C61
acore_world: 2026_08_26_01_ascension_appearance_item_templates.sql EC1B200 -> 91203FA
2 hash(es) converted
```

Why: the repack database was made on Windows, where the updater hashes SQL files after turning CRLF into LF; Linux
hashes the raw bytes (`UpdateFetcher::ReadSQLUpdate`). Files stored with CRLF in the repository then look changed
and are re-applied; `rev_1787754600000000000.sql` fails when re-applied
(`ERROR 1062 … Duplicate entry '0-2048-197' for key 'playercreateinfo_spell_custom.PRIMARY'`) and worldserver stops.
The script only changes a hash when the recorded value is exactly the LF form of the file, so it is safe to run
again (`0 hash(es) converted`).

**Live configuration** from the release templates:

```bash
cd /opt/coa/etc
for f in $(cd $R/etc && find . -name '*.conf.dist' -printf '%P\n'); do
  [ -f "${f%.dist}" ] || cp "$R/etc/$f" "${f%.dist}"
done
```

Every module needs its `.conf`: without it the module silently uses code defaults. Then edit:

| File | Setting | Value |
| --- | --- | --- |
| `worldserver.conf` | `DataDir` | `"/opt/coa/data/current"` |
| `worldserver.conf`, `authserver.conf` | `SourceDirectory` | `"/opt/coa/current/source"` |
| `worldserver.conf`, `authserver.conf` | `LogsDir` | `"/opt/coa/logs"` |
| `worldserver.conf`, `authserver.conf` | `LoginDatabaseInfo` | `"127.0.0.1;3306;acore;CHANGE_ME;acore_auth"` |
| `worldserver.conf` | `WorldDatabaseInfo`, `CharacterDatabaseInfo` | same with `acore_world`, `acore_characters` |
| `modules/coa.conf` | `CoA.AllowRemoteClients` | `1` |

`SourceDirectory` is mandatory: the value compiled into the binary is the build container's path, which does not
exist here, and worldserver and authserver refuse to start ("The given source directory … does not exist").
`CoA.AllowRemoteClients = 1`: otherwise the Ascension protocol is only enabled for connections from `127.0.0.1` and
remote CoA clients cannot play correctly. (Releases older than the `CoA.*` rename use
`modules/mod_ascension_compat.conf` and `AscensionCompat.AllowRemoteClients`.)

**Realm address** (not tested with a public address): the dump registers `127.0.0.1:8085`.

```bash
mysql -e "UPDATE acore_auth.realmlist SET address = 'PUBLIC_IP_OR_DNS', localAddress = '127.0.0.1' WHERE id = 1;"
```

Open TCP 3724 and 8085 to players; keep 3306 closed.

**Deploy**: `/opt/coa/coa-deploy-release.sh $ID` (next section).

**GM account**: the repack ships `local` / `local` (GM level 3). Change it at once in the worldserver console
(`screen -r coa-world`): `account set password local NEW_PASSWORD NEW_PASSWORD`.

## Deploying a release

When the build server announces a release:

```bash
sudo -iu coa
cat /opt/coa/releases/<id>/RELEASE.md
/opt/coa/coa-deploy-release.sh <id>
```

The script:

1. refuses a release without `.complete`, with a checksum mismatch, built for another OS, with a missing library,
   or whose client data version is not in `/opt/coa/data`;
2. shows `RELEASE.md` (in `less`, `q` to continue);
3. refuses if a `.conf` for a shipped `.conf.dist` is missing, and lists keys present in a `.conf.dist` but missing
   from the live `.conf` (the code default applies to those);
4. asks for confirmation, then takes a pre-deploy backup set of the three databases with `coa-backup.sh predeploy`
   (`/opt/coa/backups/predeploy/<timestamp>/`, see [backup.md](backup.md));
5. stops worldserver (`server shutdown 5` in its console), waits until the process has exited (up to
   `COA_STOP_TIMEOUT`, 1800 s; if it is still saving, it stops there without switching anything), then stops
   authserver;
6. switches `/opt/coa/current` and `/opt/coa/data/current`, logs the change in `/opt/coa/deploy.log`;
7. starts worldserver in `screen` session `coa-world`, waits for `(worldserver-daemon) ready...`, and prints the
   updater lines (`Applying update`, `Reapplying update`, `Applied N queries`, errors);
8. starts authserver in `screen` session `coa-auth`;
9. keeps the last 3 releases (`COA_KEEP_RELEASES`) and deletes older ones.

Test run, update from `b3717c137` to `47dd22ffe` (424 new SQL files announced in `RELEASE.md`), 2 min 24 s in total:

```
>> verifying checksums
>> backing up databases to /opt/coa/backups/20260927-115454-before-20260927-1154-47dd22f.sql.gz
>> stopping servers
>> starting worldserver (SQL updates are applied now), log: /opt/coa/logs/world-console-20260927-1154-47dd22f-….log
>> Auth database is up-to-date! Containing 13 new and 10 archived updates.
>> Applied 5 queries. Containing 10 new and 29 archived updates.
>> Applied 419 queries. Containing 753 new and 2389 archived updates.
>> 20260927-1154-47dd22f is live (previous: 20260927-1142-b3717c1)
```

That run used an earlier version of the script that wrote a single dump file. It now takes a backup set and prints
`>> backing up databases` then `>> backup: /opt/coa/backups/predeploy/<timestamp>/databases.sql.gz` (seen in the
backup and restore tests).

In that update the CoA module configuration was renamed (`mod_ascension_compat.conf` became `coa.conf`) and seven
modules were added: the first attempt stopped with `error: /opt/coa/etc/modules/coa.conf missing: create it from …`
before touching anything. Creating the missing files is the same loop as in the first installation:

```bash
R=/opt/coa/releases/<id>
cd /opt/coa/etc
for f in $(cd $R/etc && find . -name '*.conf.dist' -printf '%P\n'); do
  [ -f "${f%.dist}" ] || { cp "$R/etc/$f" "${f%.dist}"; echo "created ${f%.dist}"; }
done
```

then set the values you need in the new files (e.g. `CoA.AllowRemoteClients = 1` in `modules/coa.conf`). Files
left behind by a rename (`modules/mod_ascension_compat.conf`) are no longer read and can be deleted.

### What to read in RELEASE.md

- **Client data changed**: the build server must have shipped the new data folder; players need the matching client
  patch.
- **WARNING: modified SQL updates**: these files will be re-applied if your database already has them. Ask the build
  side whether they are safe to run twice before deploying.
- **Configuration keys added**: copy them from `/opt/coa/releases/<id>/etc/…conf.dist` into the live `.conf`. A key
  not in the live file uses its code default, which may differ from the `.dist` value. Example seen in the test:
  a `worldserver.conf` created from an older release had no `Logger.coa`, so the CoA startup line
  (`Ascension compatibility enabled; …`) was missing from the logs; the deploy script lists such keys under `note:`.

### Worldserver not ready

The script stops and prints the backup path. Look at the console log it names
(`/opt/coa/logs/world-console-<id>-<date>.log`).

- An SQL error during `Applying update` / `Reapplying update`: the database may be partly updated. Roll back and
  restore the backup taken just before (the script prints this exact command):

  ```bash
  /opt/coa/coa-deploy-release.sh --rollback <previous-id> --restore /opt/coa/backups/predeploy/<timestamp>/databases.sql.gz
  ```

- Anything else before the updater ran (bad config, missing file): fix it and run the deploy again.

`--rollback` skips the checksum and `RELEASE.md` steps, backs up the current databases, stops the servers, loads the
`--restore` backup (while nothing is running), switches back to an older release still present in
`/opt/coa/releases`, and starts it. Tested three times in a row (47dd22f → b3717c1 → 47dd22f → b3717c1); a restore
took 5 to 7 minutes. Backups contain `DROP DATABASE`, so tables created by the newer release disappear too.
Rolling back binaries without `--restore` is only safe when the newer release applied no SQL update.

## Daily operations

| Task | Command (as `coa`) |
| --- | --- |
| worldserver console | `screen -r coa-world`, detach with Ctrl+A then D |
| stop cleanly | in the console: `server shutdown 60` (seconds), then `pkill -x authserver`; worldserver keeps saving after the countdown, wait until `pgrep -x worldserver` prints nothing before starting it again |
| start without deploying | `screen -dmS coa-world -L -Logfile /opt/coa/logs/world-console-$(date +%F).log /opt/coa/current/bin/worldserver`, then `screen -dmS coa-auth /opt/coa/current/bin/authserver` |
| active release | `readlink /opt/coa/current`; history in `/opt/coa/deploy.log` |
| manual backup | `/opt/coa/coa-backup.sh daily` (scheduled backups: [backup.md](backup.md)) |

Harmless in the log: `Can't set process priority class, error: Permission denied`.
