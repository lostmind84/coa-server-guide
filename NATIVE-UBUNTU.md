# CoA server on Ubuntu 26.04 without Docker (native build)

Build the CoA fork from source, reuse the repack's ready-made database and client data, and let the worldserver
apply every newer SQL update by itself. No SQL file is ever imported by hand after the initial dump.

Status: run end to end in a clean `ubuntu:26.04` container (Ubuntu 26.04.1 LTS) on 2026-09-27 against
`origin/main` `47dd22ffe`, with the repack `main-20260919-b3717c137`. The worldserver reached
`(worldserver-daemon) ready...` and a client on the host reached the realm ports. Steps marked **(not tested)** were
not run in that session.

## Why this works

| Piece | Source |
| --- | --- |
| Server binaries | built from the fork (`jealous-sound/azerothcore-wotlk-coa`) |
| Client data (`dbc`, `maps`, `vmaps`, `mmaps`, `Cameras`) | repack `Data/` (its `dbc` is the original CoA client set) |
| Initial database | repack `Database/Clean/databases.sql.gz` (auth, characters, world) |
| Everything newer than the dump | applied automatically by worldserver at startup |

The worldserver updater (`Updates.EnableDatabases = 7`) scans `data/sql/updates/db_*`, `pending_db_*`, the archive
and the modules' `data/sql` folders **of the source tree it was built from**, compares each file with the `updates`
table of each database, and applies what is missing. Updating the server later is therefore: `git pull`, rebuild,
restart. Do not import SQL files from the repository with a SQL client: the updater would then try to apply them
again.

Do **not** build the databases from `data/sql/base` (empty database + `Updates.AutoSetup`). That path starts from
stock AzerothCore and was not tested with the CoA content; the repack dump is the supported starting point.

## 1. Packages

```bash
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git cmake make gcc g++ clang libssl-dev libbz2-dev libreadline-dev libncurses-dev \
  libboost-all-dev default-libmysqlclient-dev libstdc++-16-dev mysql-server screen curl unzip
```

`libstdc++-16-dev` is required on 26.04: clang 21 links against the GCC 16 toolchain while the default g++ is
GCC 15 (same list as `apps/installer/includes/os_configs/ubuntu.sh`).
Versions installed in the test: clang 21.1.8, cmake 4.2.3, MySQL 8.4.11, Boost 1.90.

MySQL on a normal host: `sudo systemctl enable --now mysql`. (In the test container there is no systemd, so
`mysqld --user=mysql &` was started by hand.)

## 2. Service account and source

```bash
sudo useradd -m -s /bin/bash acore
sudo -iu acore
git clone --depth 1 -b main https://github.com/jealous-sound/azerothcore-wotlk-coa.git ~/azerothcore
```

Keep this checkout: the updater reads the SQL files from it at every start (path compiled into the binary; it can
be overridden with `SourceDirectory` in `worldserver.conf`).

## 3. Build and install

```bash
mkdir -p ~/azerothcore/build && cd ~/azerothcore/build
cmake .. -DCMAKE_INSTALL_PREFIX=$HOME/azeroth-server \
  -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_WARNINGS=1 -DTOOLS_BUILD=none \
  -DSCRIPTS=static -DMODULES=static
make -j"$(nproc)"
make install
```

The configure output must list the CoA modules under `Modules configuration (static)` (`mod-coa-challenges`,
`mod-worldforged-pickups`, …). Build time in the test: 4 min 35 s on 32 threads.

Result: `~/azeroth-server/bin/{authserver,worldserver}` and `~/azeroth-server/etc/*.conf.dist`,
`~/azeroth-server/etc/modules/*.conf.dist`.

## 4. Client data

Copy the repack `Data` folder (3.8 GB) to the server, e.g. `/home/acore/data`:

```bash
rsync -a --info=progress2 CoA-Repack/Data/ acore@SERVER:/home/acore/data/
ls /home/acore/data        # Cameras dbc maps mmaps vmaps
```

Use this folder as is. Do not use the stock AzerothCore client data and do not run the AzerothCore data
downloader: without the CoA DBC files the core starts, but CoA content is broken.

## 5. Database

As root / an admin user:

```bash
sudo mysql <<'SQL'
CREATE USER 'acore'@'localhost' IDENTIFIED BY 'CHANGE_ME';
GRANT ALL PRIVILEGES ON acore_auth.*       TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_characters.* TO 'acore'@'localhost';
GRANT ALL PRIVILEGES ON acore_world.*      TO 'acore'@'localhost';
SQL

zcat CoA-Repack/Database/Clean/databases.sql.gz | sudo mysql
```

The dump creates the three databases itself (`DROP DATABASE IF EXISTS` + `CREATE DATABASE`): running it again
wipes them, characters included. Import time in the test: about 4 min 30 s.

Check:

```bash
sudo mysql -e "SELECT table_schema, COUNT(*) FROM information_schema.tables
  WHERE table_schema LIKE 'acore%' GROUP BY 1; SELECT username FROM acore_auth.account;"
```

Test result: 22 / 140 / 327 tables, one account `LOCAL`.

### One-time fix: an update hashed differently on Windows and Linux

The repack database was produced on Windows. `data/sql/updates/pending_db_world/rev_1787754600000000000.sql` is
stored with CRLF line endings, and the updater hashes files through a text-mode `std::ifstream`
(`UpdateFetcher::ReadSQLUpdate`): Windows turns CRLF into LF before hashing, Linux does not. On Linux the file looks
"changed", the updater reapplies it and the worldserver stops with:

```
>> Reapplying update "rev_1787754600000000000.sql" '563E4DD' -> '9AB2C61' (it changed)...
ERROR 1062 (23000) at line 450: Duplicate entry '0-2048-197' for key 'playercreateinfo_spell_custom.PRIMARY'
Could not update the World database, see log for details.
```

The content is identical apart from line endings, so recording the Linux hash is correct. Pick **one** option:

**Option A — recommended: record the Linux hash once** (tested). Updater settings stay at their defaults.
`scripts/coa-fix-windows-hashes.sh ~/azerothcore` does this for every CRLF file of the checkout (it found
`rev_1787754600000000000.sql` and `2026_08_26_01_ascension_appearance_item_templates.sql` against a `b3717c137`
checkout); the manual equivalent for the one file that matters with current `main`:

```bash
sudo mysql -e "UPDATE acore_world.updates SET hash = '9AB2C61CBDE30910A9044DE96CC7EF4C64C6D391'
  WHERE name = 'rev_1787754600000000000.sql' AND hash = '563E4DD451533A7E56EF69D7536127BE836026BD';
  SELECT ROW_COUNT();"
```

`ROW_COUNT()` must be `1`. The new hash is `sha1sum` of the file in your checkout; check it matches before running
the update (`sha1sum ~/azerothcore/data/sql/updates/pending_db_world/rev_1787754600000000000.sql`). If it differs,
the file really changed upstream: stop and investigate instead.

**Option B — no database edit** (tested): in `worldserver.conf` set `Updates.Redundancy = 0`. Files already
recorded in `updates` are then skipped by name and never reapplied; new files are still applied. Trade-off: if a
maintainer edits an update file that your database already applied, the edit is ignored silently (this happened to
a dozen files in the repository history).

## 6. Configuration

```bash
cd ~/azeroth-server/etc
cp authserver.conf.dist authserver.conf
cp worldserver.conf.dist worldserver.conf
for f in modules/*.conf.dist; do cp "$f" "${f%.dist}"; done
mkdir -p ~/azeroth-server/logs
```

Create **every** module `.conf`: without it, module settings silently fall back to code defaults.

Edit:

| File | Setting | Value |
| --- | --- | --- |
| `worldserver.conf` | `DataDir` | `"/home/acore/data"` |
| `worldserver.conf`, `authserver.conf` | `LogsDir` | `"/home/acore/azeroth-server/logs"` |
| `worldserver.conf`, `authserver.conf` | `LoginDatabaseInfo` (and `WorldDatabaseInfo`, `CharacterDatabaseInfo` in worldserver) | `"127.0.0.1;3306;acore;CHANGE_ME;acore_…"` |
| `modules/coa.conf` | `CoA.AllowRemoteClients` | `1` for any client not on the server itself |
| `worldserver.conf` | `Updates.Redundancy` | `0` only if you chose option B |

`CoA.AllowRemoteClients`: the Ascension protocol (plaintext world headers, extension opcodes, class-10 mapping) is
only enabled for loopback connections otherwise, and a remote CoA client cannot play correctly.

The repack's `Settings/*.template` files use older key names (`AscensionCompat.*`, `AscensionCompat.DbcDirectory`):
do not copy them over the new `.conf` files. Current settings are `CoA.*` in `modules/coa.conf`. The repack
enables `Ascension.Manastorm.Enable = 1`; the `.dist` default is `0`.

## 7. Realm address (not tested with a public address)

The dump registers the realm at `127.0.0.1:8085`. For clients on other machines set the address the clients use:

```bash
sudo mysql -e "UPDATE acore_auth.realmlist SET address = 'PUBLIC_IP_OR_DNS', localAddress = '127.0.0.1'
  WHERE id = 1; SELECT id, name, address, port FROM acore_auth.realmlist;"
```

Open TCP 3724 (auth) and 8085 (world) in the firewall. Keep MySQL (3306) closed to the outside.

## 8. Start

```bash
cd ~/azeroth-server/bin
screen -dmS world -L -Logfile ~/azeroth-server/logs/world-console.log ./worldserver
screen -dmS auth ./authserver
```

First start: the updater applies everything newer than the dump. In the test:

```
>> Auth database is up-to-date! ...
>> Character database is up-to-date! ...
>> Applied 345 queries. Containing 753 new and 2463 archived updates.
AzerothCore rev. 47dd22ffe6d0 ... (worldserver-daemon) ready...
Ascension compatibility enabled; consuming extension opcodes 0x051F-0x09D3; collection data ready
```

Watch with `grep -E "Applying|Reapplying|Could not|ready" ~/azeroth-server/logs/world-console.log`.
Any `Reapplying update` line deserves a look (see section 5). Console: `screen -r world`, detach with Ctrl+A then D.

Harmless in the log: `Can't set process priority class, error: Permission denied`.

Running as systemd services instead of `screen` was **not tested**.

## 9. Accounts

The repack ships a GM level 3 account `local` / `local`. On any reachable server change its password first, from
the worldserver console:

```
account set password local NEW_PASSWORD NEW_PASSWORD
account create NAME PASSWORD
account set gmlevel NAME 3 -1
```

## 10. Client

In the client folder, `Data/enUS/realmlist.wtf` and `WTF/Config.wtf` (`SET realmList`):

```
set realmlist SERVER_ADDRESS
```

Append `:PORT` only if authserver does not listen on 3724.

## 11. Updating the server

```bash
sudo -iu acore
cd ~/azerothcore && git pull
cd build && make -j"$(nproc)" && make install
# stop: in the worldserver console, "server shutdown 10"; stop authserver
# start again (section 8): new SQL updates are applied at startup
```

Compare the new `.conf.dist` files with your `.conf` after an update: new settings are not added automatically.
Back up first: `mysqldump --databases acore_auth acore_characters acore_world | gzip > backup-$(date +%F).sql.gz`.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Reapplying update "…" (it changed)` then `Duplicate entry` | Windows/Linux hash difference, section 5 |
| `Unknown column …` at start | database newer than the binary: rebuild from the matching revision |
| Client logs in but CoA features are missing or broken | `CoA.AllowRemoteClients = 0`, or stock client data in `DataDir` |
| Settings seem ignored | the module `.conf` file is missing (only `.conf.dist` exists) |
