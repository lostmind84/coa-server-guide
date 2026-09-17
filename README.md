# Conquest of Azeroth (CoA) server on Linux with Docker

Step-by-step guide to run the **Conquest of AzerothCore** server on a Linux PC without installing its build
dependencies on the host, laid out so it can later move to a VPS with few changes.

- French version: [README.fr.md](README.fr.md)
- Commands only: [QUICKSTART.md](QUICKSTART.md)
- Automated steps 8–11: [`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh)

Status on 2026-09-15: steps 1–13 were run and verified on the test machine: server up, Ascension data loaded, GM
password changed, client logged in, custom-class character created and **in the world**. The setup script was
syntax-checked and its hash conversion was checked read-only against the running database; a full run on a clean
machine has not been done. In-game gameplay beyond world entry was not tested.

| Item | Version used |
| --- | --- |
| Server repository | [`jealous-sound/azerothcore-wotlk-coa`](https://github.com/jealous-sound/azerothcore-wotlk-coa) `main` at `bb1d48a5f` (PR #235) + Boost build fix ([PR #243](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243)) |
| Repack | `ability-fixes-20260914` (source `126ee7d`, after PRs #130/#133) |
| Client patch | `ability-fixes-20260914`, client revision 3 |
| Test machine | Arch Linux, Docker + Compose + buildx, 16 cores, 125 GB RAM, uid 1000 |

---

## 1. The pieces

- **Client**: the game the player installs (~44 GB). World of Warcraft 3.3.5a modified by Ascension. Windows
  program: Linux needs Wine/Proton. It renders the game; it decides nothing.
- **Server**: two programs and a MySQL database.
  - `authserver` (port 3724): checks the account, sends the realm list.
  - `worldserver` (port 8085): runs the world (spells, AI, quests…).
  - MySQL 8.4 with three databases: `acore_auth` (accounts, realms), `acore_world` (game content),
    `acore_characters` (characters).
- **Server data** (`dbc`, `maps`, `vmaps`, `mmaps`, `Cameras`): files extracted from the client so the server
  knows spells, terrain, line of sight and paths. Since jealous-sound/azerothcore-wotlk-coa#1498 `dbc/` must hold
  the CoA client's own DBC set, extracted from the original client (step 8).
- **Client patch**: files copied over the client (`Ascension.exe`, `Extensions.dll`, `patch-B.MPQ`,
  `patch-T.MPQ`, `realmlist.wtf`) to match the CoA server.
- **Repack**: a **pre-built, ready-to-run Windows server** (executables, portable MySQL, filled databases,
  server data, configs, `.bat` launchers). This guide runs none of its executables: it reuses its **server data**
  and its **database dump**.

Login flow: client → `realmlist.wtf` → authserver (3724) → realm address from `acore_auth.realmlist` →
worldserver (8085).

Worldserver startup (`src/server/apps/worldserver/Main.cpp`): load configs (including module configs) → connect
to databases (and run SQL updates if enabled) → load the world (DBC, spells, templates, scripts, maps) → open port
8085 → world update loop.

## 2. How to run the server

| Option | Verdict |
| --- | --- |
| Native on Arch | Not recommended: MySQL 8.4 is not packaged (MariaDB is **unsupported**, error ACE00043), Boost headers needed, distribution not officially supported (Ubuntu 24.04/26.04, Debian 12/13 are). |
| Ubuntu VM | Works and fully isolated, but reserves resources and the client connects to a remote IP. |
| **Docker** | **Chosen**: all dependencies stay inside Ubuntu 24.04 images. The repository already ships `docker-compose.yml`. |

Why not build on the host and copy binaries into Docker: no speed gain (Docker is not a VM on Linux) and binaries
are likely incompatible (glibc 2.44 on Arch vs 2.39 in Ubuntu 24.04, different Boost/OpenSSL/libmysqlclient). For
frequent rebuilds, use the `ac-dev-server` service (`dev` profile), which keeps the build directory and ccache in
volumes.

The official repack does not use Docker: it targets Windows players (double-click `Start_All_Server.bat`). The
repository's `docker-compose.yml` comes from stock AzerothCore and has nothing CoA-specific; this guide adds the
CoA steps.

## 3. What Docker builds

`apps/docker/Dockerfile` compiles everything once (`build` stage: Ubuntu 24.04, clang, Ninja, ccache,
`-DAPPS_BUILD=all -DTOOLS_BUILD=all -DSCRIPTS=static -DMODULES=static`) and copies each binary into its image:

| Image | Content |
| --- | --- |
| `acore/ac-wotlk-worldserver:master` | `worldserver` (core + scripts + `mod-ascension-compat` module) |
| `acore/ac-wotlk-authserver:master` | `authserver` |
| `acore/ac-wotlk-db-import:master` | `dbimport` + `data/` + module SQL |
| `acore/ac-wotlk-client-data:master` | script downloading the **stock** v20.0 client data |
| `mysql:8.4` | official image, not built |

System dependencies in the build image: Boost 1.83, OpenSSL, MySQL client, readline, zlib, bzip2. Bundled in
`deps/`: argon2, g3dlite, jemalloc, libmpq, recastnavigation, fmt, etc.

## 4. Directory layout

Server-side files live in `/srv/coa` (the conventional location for data served by a machine) so the same paths
work on a VPS. Workstation-only files stay in the home directory.

```
~/Projects/azerothcore-wotlk-coa/   git repository (code) + .env (Docker Compose settings, git-ignored)
/srv/coa/                           server side: identical on the PC and on a VPS
├── coa.env                         server settings passed into the containers (AC_* variables)
├── server-data/                    dbc, maps, vmaps, mmaps (3.3 GB)
├── etc/                            server configs (created by the containers) + etc/modules/*.conf
├── logs/                           server, import and build logs
└── backups/                        MySQL dumps
~/CoaServer/                        workstation only, never on a server
├── client/                         ascension-live/ (client) + CoA-Client-Patch/
├── repack/                         CoA-Repack/: reference, never executed
├── downloads/
└── backups/                        replaced client files
```

The MySQL data lives in the Docker volume `azerothcore-wotlk-coa_ac-database`, not in `/srv/coa`.

```bash
sudo mkdir -p /srv/coa && sudo chown "$(id -u):$(id -g)" /srv/coa
mkdir -p /srv/coa/{etc/modules,logs,backups,server-data}
mkdir -p ~/CoaServer/{downloads,client,repack,backups}
```

The owner must be uid 1000: the images are built with `DOCKER_USER_ID=1000` and the containers write to `etc/`
and `logs/`.

## 5. Build the images

```bash
git clone https://github.com/jealous-sound/azerothcore-wotlk-coa.git ~/Projects/azerothcore-wotlk-coa
cd ~/Projects/azerothcore-wotlk-coa
docker compose config --services         # must list 5 services
docker compose build 2>&1 | tee /srv/coa/logs/build-$(date +%F).log
docker images | grep acore
docker run --rm --entrypoint /azerothcore/env/dist/bin/worldserver acore/ac-wotlk-worldserver:master --version
```

- `./acore.sh docker build` runs exactly `docker compose build`.
- First build observed: 1,340 targets in ~392 s, 0 errors, 55 warnings. A rebuild after a one-file change took
  ~23 s of compilation thanks to ccache.
- On `main` at `bb1d48a5f` the build fails until PR #243 is merged (see [Known pitfalls](#known-pitfalls)).
  Apply the one-line fix first:

```bash
grep -q "boost/bind/placeholders.hpp" modules/mod-ascension-compat/src/CoAGameplayTest.cpp || \
  sed -i 's|#include <boost/property_tree/json_parser.hpp>|#include <boost/bind/placeholders.hpp>\n&|' \
  modules/mod-ascension-compat/src/CoAGameplayTest.cpp
```

## 6. Download and verify the client, patch and repack

The fork author shares the client, client patch and repack in the project's Discord channel. Extract them into
`~/CoaServer/client/` and `~/CoaServer/repack/`.

**Do not run any `.bat` or `.exe`.** Checks performed:

- The 9 repack `.bat` files only call `Runtime/python/python.exe Scripts/manage.py <action>`.
- `CoA-Client-Patch/CLIENT-RELEASE.json` lists each file's SHA256; they match, and the EXE/DLL hashes also match
  `apps/client-compat/README.md` in the repository:

| File | SHA256 |
| --- | --- |
| `Ascension.exe` (manifest set to `asInvoker`) | `f4b9f6fce448194638c5b1c751483090a48c597c6272237f31b3d151b50d3114` |
| `Extensions.dll` (world address fix) | `9791801053f828d1ccdab1a4c17e64852d3ebe0fa708b91fa3674d0805d15bc8` |
| `Data/patch-B.MPQ` | `e16fd42b8a98368de9962d5c3ac07996c14f1c39798ce1fe61e90ad246c92ede` |
| `Data/patch-T.MPQ` | `ad183192246cb453673eba7be58649cbd33c00da6556b2f4906d5b357705d626` (not installed since #1498, step 7) |

- `Database/Clean/snapshot.json` holds the dump checksum (`gzipSHA256`); the setup script checks it.
- `BugReport/relay.py` sends in-game bug reports to an external service that opens public GitHub issues on the
  fork, using an embedded distribution API key. It is not used here (`CoABugReport.Enable = 0`).
- Wine is **not** a sandbox: a program run under Wine can read `$HOME` through `Z:`. Use a dedicated prefix.

Useful repack content:

| Path | Use |
| --- | --- |
| `Data/` (3.3 GB) | complete server data, including `dbc/Ascension/` |
| `Database/Clean/databases.sql.gz` | MySQL 8.4.9 dump of the 3 databases (22/117/321 tables); account `local`/`local` GM 3, no characters; world migrations up to `rev_20260914_15` |
| `Settings/*.template` | reference settings (carried over in step 9) |
| `RELEASE.json`, `RELEASE.txt` | version, binary hashes, changes |

## 7. Apply the client patch

```bash
cd ~/CoaServer/client
mkdir -p ~/CoaServer/backups/client-before-rev3
cp -a ascension-live/Ascension.exe ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ \
      ~/CoaServer/backups/client-before-rev3/
cp -a CoA-Client-Patch/Ascension.exe CoA-Client-Patch/Extensions.dll ascension-live/
cp -a CoA-Client-Patch/Data/. ascension-live/Data/
sha256sum ascension-live/Ascension.exe ascension-live/Extensions.dll \
          ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ
```

Hashes must match the table in step 6. `Data/enUS/realmlist.wtf` already contains `set realmlist 127.0.0.1`.

Since #1498 the server and players use the original client DBC set, and players must not receive the patch's
`patch-T.MPQ` (its only archive with DBC files). The launcher keeps its untouched copy as `patch-T.MPQ.ORIGINAL`:

```bash
cd ~/CoaServer/client/ascension-live/Data
mkdir -p ~/CoaServer/backups/client-rev4 && mv patch-T.MPQ ~/CoaServer/backups/client-rev4/
cp patch-T.MPQ.ORIGINAL patch-T.MPQ
```

## 8. Server data

```bash
cp -a ~/CoaServer/repack/CoA-Repack/Data/. /srv/coa/server-data/
echo "INSTALLED_VERSION=v20.0" > /srv/coa/server-data/data-version
```

The repack's `dbc/` is not the client set the worldserver now requires (it exits with `DataDir does not hold the
CoA client DBC set`). Extract the set from the original client with the repository's tool and copy it over.
It needs [mpqcli](https://github.com/TheGrayDot/mpqcli) (Linux release binary, e.g. in `~/.local/bin`):

```bash
cd ~/Projects/azerothcore-wotlk-coa
out=~/CoaServer/client-dbc/original-$(date +%F)
python3 apps/coa-dbc/client_dbc.py extract ~/CoaServer/client/ascension-live/Data "$out" --original \
  --mpqcli "$(command -v mpqcli)"                       # ends with "110 core tables checked, 0 problems"
cp -a --reflink=auto /srv/coa/server-data/dbc /srv/coa/backups/dbc-$(date +%F)
cp "$out"/*.dbc /srv/coa/server-data/dbc/
```

`--original` reads the launcher's untouched `NAME.ORIGINAL` archives. Here the set has 368 tables (patch-M 288,
patch-S 48, stock locale archives 31, patch-T 1). Repeat after a client update, then restart the worldserver.

`ac-client-data-init` (a dependency of the servers) downloads stock data and extracts it with `unzip -o`, which
would overwrite the CoA DBC files. It skips the download when `data-version` matches its version
(`apps/installer/includes/functions.sh`); the file above uses that existing check.

## 9. Configuration

Two different files:

- **`.env` in the repository** (next to `docker-compose.yml`, the only place Compose reads it): MySQL root
  password, ports, host paths.
- **`/srv/coa/coa.env`**: server settings injected into authserver/worldserver. It must not contain the password.

```bash
cd ~/Projects/azerothcore-wotlk-coa
cat > .env <<EOF
DOCKER_DB_ROOT_PASSWORD=$(openssl rand -hex 16)
DOCKER_DB_EXTERNAL_PORT=127.0.0.1:3306
DOCKER_AUTH_EXTERNAL_PORT=127.0.0.1:3724
DOCKER_WORLD_EXTERNAL_PORT=127.0.0.1:8085
DOCKER_SOAP_EXTERNAL_PORT=127.0.0.1:7878
DOCKER_VOL_ETC=/srv/coa/etc
DOCKER_VOL_LOGS=/srv/coa/logs
DOCKER_VOL_DATA=/srv/coa/server-data
DOCKER_AC_ENV_FILE=/srv/coa/coa.env
EOF
chmod 600 .env
git check-ignore -v .env                  # .gitignore:21:/.env*

cp conf/dist/env.ac /srv/coa/coa.env
cat >> /srv/coa/coa.env <<'EOF'

# CoA settings from the repack (Settings/*.template)
AC_ASCENSION_COMPAT_ALLOW_REMOTE_CLIENTS=1
AC_ASCENSION_MANASTORM_ENABLE=1
AC_PLAYER_START_CUSTOM_SPELLS=1
EOF

for f in modules/*/conf/*.conf.dist; do cp -n "$f" "/srv/coa/etc/modules/$(basename "${f%.dist}")"; done

docker compose config | grep -E "host_ip|source: /srv|AC_ASCENSION|AC_PLAYER_START"
```

- The password is generated inside the file and never displayed; later commands read it inside the container
  (`$MYSQL_ROOT_PASSWORD`). Avoid `;`, `$`, spaces and quotes if you set it by hand.
- Environment variable names follow `IniKeyToEnvVarKey` (`src/common/Configuration/Config.cpp`): `AC_` prefix,
  dots to `_`, `_` between a lowercase and an uppercase letter, uppercase.
- `AscensionCompat.DbcDirectory` was removed by #1498 (collections read `dbc/`); delete it from older
  `coa.env` and `etc/modules/mod_ascension_compat.conf` files.
- Module `.conf` files are required: worldserver loads `etc/modules/<name>.conf` only (`modules/CMakeLists.txt`
  strips `.dist`), and the containers only create `worldserver.conf`, `authserver.conf` and `dbimport.conf`.
- Expected check output: `host_ip: 127.0.0.1` (4×), sources `/srv/coa/etc`, `/srv/coa/logs`,
  `/srv/coa/server-data`, and the 3 CoA variables for authserver and worldserver.

## 10. Database

```bash
docker compose up -d ac-database
docker compose ps                         # wait for "healthy"

zcat ~/CoaServer/repack/CoA-Repack/Database/Clean/databases.sql.gz \
  | docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

docker compose exec ac-database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM acore_world.updates; SELECT COUNT(*) FROM acore_world.creature_template; SELECT id, username FROM acore_auth.account;"'
```

Expected: `3057`, `31237`, one account `LOCAL`. The `Using a password on the command line` warning is normal.

Fix the realm port (the dump holds `16085`) and convert two Windows update hashes:

```bash
docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
UPDATE acore_auth.realmlist SET port = 8085 WHERE id = 1;
UPDATE acore_world.updates SET hash = '9AB2C61CBDE30910A9044DE96CC7EF4C64C6D391'
  WHERE name = 'rev_1787754600000000000.sql' AND hash = '563E4DD451533A7E56EF69D7536127BE836026BD';
UPDATE acore_world.updates SET hash = '91203FA3DBE929E388DA88BD0822BFA140355C4B'
  WHERE name = '2026_08_26_01_ascension_appearance_item_templates.sql' AND hash = 'EC1B200FDA9C234431A90717D347F6A42444676F';
SELECT id, address, port FROM acore_auth.realmlist;
SELECT name, hash FROM acore_world.updates
  WHERE name IN ('rev_1787754600000000000.sql', '2026_08_26_01_ascension_appearance_item_templates.sql');
SQL
```

Why: these two files contain CRLF line endings. The Windows updater hashes them after converting to LF; on Linux
the raw bytes are hashed. A different hash makes `dbimport` **reapply** the file
(`src/server/database/Updater/UpdateFetcher.cpp`), and `rev_1787754600000000000.sql` deletes and reinserts
`playercreateinfo_item`, `playercreateinfo_spell_custom` and `ascension_custom_class_spell`. The same correction
exists in the repository (`apps/coa-world/world_data.py`, `reconcile_ledger`). The setup script computes these
pairs from the checkout instead of hard-coding them.

Apply the migrations that are newer than the dump:

```bash
docker compose up ac-db-import 2>&1 | tee /srv/coa/logs/db-import-$(date +%F).log
docker compose ps -a ac-db-import         # Exited (0)
grep -E "Applying|Reapplying|Applied|auto populating" /srv/coa/logs/db-import-$(date +%F).log
```

Observed: 1 auth, 1 characters and 5 world updates applied, no `Reapplying update`, no `auto populating`.

## 11. Start the server

```bash
docker compose up -d ac-authserver ac-worldserver
docker compose logs -f ac-worldserver     # wait for "(worldserver-daemon) ready...", Ctrl+C stops following only
```

Checks:

```bash
docker compose logs --no-color ac-worldserver > /srv/coa/logs/worldserver-start-$(date +%F).log
grep -E "Using modules configuration|> mod_ascension|> coa_bugreport|Failed open|Ascension collection data|Unable to open Ascension|World Initialized|worldserver-daemon\) ready" \
  /srv/coa/logs/worldserver-start-$(date +%F).log
docker compose logs --no-color ac-authserver | tail -5
docker compose ps -a
```

Observed:

- `Using modules configuration:` with `> coa_bugreport.conf` and `> mod_ascension_compat.conf`.
- `Loaded Ascension collection data: 42884 appearances, 202913 item mappings, 2348 item sets, 10678 vanity entries`.
- `WORLD: World Initialized In 0 Minutes 9 Seconds`, then `(worldserver-daemon) ready...`.
- authserver: `Added realm "AzerothCore" at 127.0.0.1:8085.`
- `ac-client-data-init` and `ac-db-import` exit with code 0; the other three containers stay up.

Not errors:

- `Can't set process priority class, error: Permission denied`: the container may not change its priority.
- `/srv/coa/logs/Errors.log` (~93,000 lines): data validation warnings, mostly custom items (`wrong LimitCategory`,
  `item_set_names`, `RandomProperty`) plus some `spell_proc`/`trainer_spell` entries. None mention Ascension, CoA
  or Manastorm.
- `AscensionCompat.AllowRemoteClients` is not listed among "Found config value … from environment variable": it is
  read without logging (`WorldSocket.cpp`), but the environment value is still used
  (`ConfigMgr::GetValueDefault`). `docker compose exec ac-worldserver printenv | grep AC_ASCENSION` shows it.

## 12. Change the GM account password

The `local`/`local` account is published with the repack.

```bash
docker compose attach ac-worldserver
```

```
account set password local NEW_PASSWORD NEW_PASSWORD
```

The console answers `The password was changed`. Detach with **Ctrl+P then Ctrl+Q**; Ctrl+C stops the server.
The console needs the account name and the password twice; `.account set password …` also works.

## 13. Launch the client

`Ascension.exe` and `Extensions.dll` are 32-bit Windows binaries. They run with `umu-run` and GE-Proton
(variables from `umu(1)`), **with `DivxTac.dll` disabled**:

```bash
cd ~/CoaServer/client/ascension-live
WINEPREFIX="$HOME/Games/umu/coa-client" GAMEID=0 \
PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64" \
WINEDLLOVERRIDES="divxtac=d" \
umu-run Ascension.exe
```

Verified on 2026-09-15: login, character creation (custom class 23) and world entry.

- Run it from the client folder (the client reads `Data/` relative to it).
- Follow the server side with `docker compose logs -f ac-authserver ac-worldserver`.
- Without `divxtac=d` the client freezes on the loading screen at 100% (see [Known pitfalls](#known-pitfalls)).
  Removing `DivxTac.dll` from the client folder has the same effect (reported by Linux users on Discord).

### Launcher

[`scripts/coa-client`](scripts/coa-client) wraps this command:

```bash
cp scripts/coa-client ~/.local/bin/ && chmod +x ~/.local/bin/coa-client
coa-client            # launch (output to ~/CoaServer/logs/client.log when not in a terminal)
coa-client --debug    # launch with a Proton log (~/CoaServer/logs/steam-0.log)
coa-client --kill     # stop a frozen client only
```

It refuses to start a second client and warns when no authserver answers on `127.0.0.1:3724`. For a desktop menu
entry, copy [`scripts/coa-client.desktop`](scripts/coa-client.desktop) to `~/.local/share/applications/`, replace
`USER`, then run `update-desktop-database ~/.local/share/applications`.

### Debugging the client

`coa-client --debug` sets `PROTON_LOG=1`: Proton writes `+timestamp,+pid,+tid,+seh,+unwind,+threadname,+debugstr,
+loaddll` traces. This is not an attached debugger; `Extensions.dll` contains anti-debug checks, so avoid real
debuggers. Useful searches in the log: `trace:loaddll` (last DLLs loaded before a freeze), `err:sync` (deadlocks,
e.g. `loader_section … blocked by`), `warn:seh`. A thread raising `0x80000003`/`0x80000004` and calling
`OutputDebugStringA "%s%s…"` every 5 seconds is the client's anti-debug watchdog, not a fault.

## Daily operations

```bash
cd ~/Projects/azerothcore-wotlk-coa
docker compose up -d ac-authserver ac-worldserver       # start (MySQL and one-shot services start too)
docker compose stop -t 60                               # stop; worldserver handles SIGTERM (Main.cpp)
docker compose logs -f ac-worldserver                   # follow logs
docker compose exec -T ac-database sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --databases acore_auth acore_characters acore_world' \
  | gzip > /srv/coa/backups/coa-$(date +%F).sql.gz      # backup
```

`-t 60` gives worldserver more than Docker's default 10 seconds to shut down; the time it actually needs was not
measured. `mysqldump` 8.4.11 is present in the `mysql:8.4` image; the backup command itself was not run yet.

## Automated setup

[`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh) runs steps 8–11 (plus the build unless
`--skip-build`), with checks:

```bash
sudo mkdir -p /srv/coa && sudo chown "$(id -u):$(id -g)" /srv/coa
~/Projects/coa-server-guide/scripts/setup-coa-server.sh \
  --repo ~/Projects/azerothcore-wotlk-coa \
  --repack ~/CoaServer/repack/CoA-Repack
```

- Verifies the dump checksum, warns when the Boost fix is missing, keeps existing `.env`, `coa.env`, data and module
  configs, never imports over an existing `acore_world`, and does not restart running servers.
- Converts every CRLF update hash found in the checkout (guarded by the Windows hash), runs `dbimport`, fails on a
  non-zero exit, warns on `Reapplying update`, waits for `(worldserver-daemon) ready`.
- Does not patch the client, change the GM password or launch the client.

## Parallel agents: server slots

One stack serves one agent at a time: a rebuild or restart by one agent silently invalidates the tests of another.
[`scripts/coa-slot`](scripts/coa-slot) (linked as `~/.local/bin/coa-slot`) runs up to three isolated stacks side by
side, so up to three agents can fix and test batches at once without a shared server lock.

| Slot | Compose project | Containers | Image tag | Ports auth / world / MySQL / SOAP | Config and logs |
|------|-----------------|------------|-----------|-----------------------------------|-----------------|
| 1 | `azerothcore-wotlk-coa` | `ac-*` | `master` | 3724 / 8085 / 3306 / 7878 | `/srv/coa/etc`, `/srv/coa/logs` |
| 2 | `coa-s2` | `coa-s2-*` | `s2` | 3824 / 8185 / 3406 / 7978 | `~/CoaServer/slots/s2/{etc,logs}` |
| 3 | `coa-s3` | `coa-s3-*` | `s3` | 3924 / 8285 / 3506 / 8078 | `~/CoaServer/slots/s3/{etc,logs}` |

Slot 1 is the original server; the game client connects to it. Each slot also has its own database volume, build
clone `~/Projects/azerothcore-wotlk-coa-build-sN` (`origin` = GitHub, remote `local` = the main checkout) and Ghost
environment file `~/CoaServer/slots/sN/ghost.env`. Server data (`/srv/coa/server-data`, read-only in the
containers) is shared unless the slot was created with `--own-data`.

```bash
coa-slot list                                 # holder, deployed commit and worldserver state of every slot
coa-slot claim 2 "pets batch"                 # take a free slot (fails if another agent holds it)
coa-slot claim-issues 2 209 285 1425          # reserve issues (all or nothing, across slots)
coa-slot create 2                             # first use: config copy, build clone, database from the repack dump
coa-slot deploy 2 fix/coa-summons-pets        # checkout in the clone, build :s2, db-import, restart, wait ready
coa-slot preflight 2                          # coa-preflight.py against slot 2 (needs mpqcli)
set -a; . ~/CoaServer/slots/s2/ghost.env; set +a
go test -tags=e2e -p 1 ./e2e/coa/summonspets -count=1 -v
coa-slot compose 2 logs --tail 50 ac-worldserver
coa-slot stop 2 && coa-slot release 2         # batch done
```

- `create` copies `/srv/coa/etc` once (Ghost tests edit `worldserver.conf`), seeds slots 2 and 3 from the repack
  dump like `setup-coa-server.sh` (realm port set to the slot's world port, CRLF hashes converted), and writes
  `compose.env`, `compose.override.yml` (container names) and `ghost.env` (ports, DBC path, config path).
- `deploy` takes a branch of the main checkout (worktree branches included, no push needed), a branch of origin or
  a commit. A branch name that exists in the main checkout wins over origin, so deploy `origin/main`, not `main`.
  It refuses a clone with uncommitted changes and writes `branch sha date` to `~/CoaServer/slots/sN/state`.
- SQL applied by one branch stays in the slot's database. Before deploying a branch without it:
  `coa-slot reset-db N` (slots 2 and 3 only).
- `destroy N --yes` (slots 2 and 3, released first) removes containers, database volume, the slot's images and
  `~/CoaServer/slots/sN`, and keeps the build clone.
- Claims are plain files: `~/CoaServer/slots/sN/owner` (created with `noclobber`) and `~/CoaServer/slots/issues.tsv`
  (updated under `flock`). They coordinate agents; they do not block a command typed by hand.
- Resources: a running slot used about 5 GiB of RAM here (worldserver 3.8 GiB, MySQL 1.3 GiB). Builds of different
  slots wait for each other at the compile step because the Dockerfile's ccache mount is `sharing=locked`.

## Client lab for agents

[`scripts/coa-client-lab`](scripts/coa-client-lab) (linked as `~/.local/bin/coa-client-lab`) runs a separate copy
of the client so an agent can reproduce client-side issues without touching your client. The lab client runs in a
nested gamescope window (1920x1080) on Hyprland workspace 9; you can watch it there. Keyboard input and screenshots
go through gamescope's own X display, so your focus and mouse are never used. One lab client runs at a time.

```bash
coa-client-lab create                      # once: reflink copy of the client and prefix (near-zero disk space)
coa-slot claim 2 "client check"            # the lab client talks to a claimed slot
coa-client-lab preflight 2                 # server and lab client data must match
coa-client-lab start 2
coa-client-lab login <account> <password>  # GM account on that slot; takes about 90 seconds
coa-client-lab chat "/say hello"
coa-client-lab screenshot                  # prints the PNG path
coa-client-lab stop                        # warns if your own client changed meanwhile
```

The lab copy drops your accounts, remembered login and caches. After a client patch, recreate it:
`coa-client-lab destroy --yes && coa-client-lab create`. The lab client needs an account and a character on the
slot; create the character through a Ghost bot login rather than the character creation screen. Tests:
`scripts/tests/coa-client-lab.test.sh`. Design and spike results:
`docs/superpowers/specs/2026-09-17-client-issue-agent-*.md`.

## Deploying to a VPS (not tested)

Same repository, same `/srv/coa` layout. Differences:

1. Ports: `DOCKER_AUTH_EXTERNAL_PORT=3724` and `DOCKER_WORLD_EXTERNAL_PORT=8085` (all interfaces); keep MySQL and
   SOAP on `127.0.0.1`. Open only 3724/tcp and 8085/tcp in the firewall.
2. Realm address: `UPDATE acore_auth.realmlist SET address = '<public IP or DNS>' WHERE id = 1;`
3. Client: `set realmlist <server address>` in `realmlist.wtf`. The patched client accepts a remote world address
   (`apps/client-compat/README.md`) and `AllowRemoteClients = 1` is already set.
4. Images: build on the VPS, or push them to a registry under your own name (not `acore/…`, see pitfalls).
5. Data: copy `/srv/coa/server-data` and `coa.env` (`rsync`), then import a `mysqldump` made on the PC.
6. Security: new MySQL root password, GM password changed, OS kept up to date.

## Automated gameplay tests

The repository ships scenario tests that run inside a disposable worldserver with copied databases. From the
repository root, after building the server images:

    mkdir -p .cache/coa-gameplay-tests
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      build ac-gameplay-test
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      run --rm ac-gameplay-test run apps/coa-gameplay-test/scenarios/frostbolt.json

A run copies the three databases (about 3 minutes here), runs the scenario and drops the copies. Results go to
`.cache/coa-gameplay-tests/`. Details: `apps/coa-gameplay-test/README.md`.

## Known pitfalls

- **Never run `docker compose pull`** (or `./acore.sh docker pull`): locally built images use the same names as
  the official images and would be replaced by versions without the CoA module.
- **Do not run `docker compose up` on all services before steps 8–10**: it creates a stock world database and
  downloads stock client data over the CoA files.
- **Build failure since PR #235** (`bb1d48a5f`): `CoAGameplayTest.cpp` fails with
  `fatal error: no member named 'placeholders' in namespace 'boost'`. `deps/boost/CMakeLists.txt` defines
  `BOOST_BIND_NO_PLACEHOLDERS` globally, so Boost 1.83's `bind.hpp` skips `placeholders.hpp`, which the
  Boost.PropertyTree JSON parser needs. Fix: `#include <boost/bind/placeholders.hpp>` before
  `<boost/property_tree/json_parser.hpp>`. Verified: full Docker build passes (1,362/1,362). Proposed upstream in
  [PR #243](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243).
- **`.env` vs `coa.env`**: Compose settings (password, ports, paths) belong in the repository `.env`. Anything in
  `coa.env` is injected into the server containers.
- **Missing module configs**: without `etc/modules/*.conf`, module settings silently fall back to code defaults
  (e.g. `AscensionCompat.PlaintextWorldHeaders` defaults to `false` in code, `1` in the config).
- **CRLF update hashes**: a Windows-made database used by the Linux updater reapplies CRLF files unless their
  hashes are converted (step 10).
- **Client frozen at 100% on the world loading screen (Wine/Proton)**: when entering the world, `Extensions.dll`
  loads `DivxTac.dll`, a mixed-mode .NET assembly (C++/CLI, `ILONLY=False`, runtime `v4.0.30319`). Wine loads it
  through wine-mono from `_CorDllMain` while holding the DLL loader lock; the main thread never returns and every
  other thread waits on `loader_section` (Proton log: `err:sync … blocked by <main thread>`). Server side the
  character is online, and the client stops reading its socket. Fix: `WINEDLLOVERRIDES="divxtac=d"` (or move
  `DivxTac.dll` out of the client folder). Ruled out while investigating: client patch revision (rev 3 and rev 4
  behave the same), the full appearance catalog snapshot (`AscensionCompat.UnlockLocalAppearanceCatalog = 0` does
  not help), anti-cheat alerts (none recorded), the `MemoryBridge … oversized_message` line (also present in older
  working sessions).
- **Ascension client and Docker networking**: `src/server/game/Server/WorldSocket.cpp` enables the Ascension
  protocol only for loopback connections unless `AscensionCompat.AllowRemoteClients = 1`. Behind Docker networking
  the connection does not come from `127.0.0.1` (the server sees the bridge gateway, e.g. `172.19.0.1`). Until
  [PR #261](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/261) (issue #260) is merged, the Ascension
  spell-modifier layout and the class-10 mapping still require the literal address `127.0.0.1`: behind Docker,
  talent/passive modifiers are missing from client tooltips (e.g. Starcaller Moon Arrow shows 30 yd instead of 45).
- **Versions must match**: server binary, database, server DBC and client patch go together. A binary older than
  the database causes ACE00004-type errors (`Unknown column ...`).
- **World package shipped in the repository** (`data/coa-world`, `coa-world-20260912`): older than the repack dump.
  If used anyway, `apps/coa-world/world_data.py bootstrap` needs an empty world database, a MySQL 8.4 client
  (`--no-login-paths` is missing from Ubuntu's 8.0 client) and Python 3.11+. Tested: `mysql:8.4` +
  `microdnf install -y python3.12` works.
- **Stock AzerothCore client data**: enough to start the core, but without the Ascension DBC files (empty
  collections, partial CoA content).

## Contributing back

- You need write access or a GitHub fork of `jealous-sound/azerothcore-wotlk-coa` (external contributors open PRs
  from their fork): `git remote add fork https://github.com/<user>/azerothcore-wotlk-coa.git`.
- PR body follows `.github/pull_request_template.md`: *Problem and resulting behavior*, *Validation and remaining
  limits*, *Data/source dependencies* (confirm applied SQL is unchanged, no credentials, profiles or game archives).
- `.github/CONTRIBUTING.md`: focused changes; report source checks, builds and in-game tests separately. GitHub
  Actions only runs repository checks, not a server build; PRs from forks may wait for maintainer approval to run.
- Commit/PR title: `Type(Scope): Subject`, max 50 characters, imperative, capitalized, no period; body lines max
  72 characters. Everything in English. Disclose AI assistance.
- Local checks matching CI: `python apps/codestyle/codestyle-cpp.py --files <path>`,
  `python -B tools/check_repository.py`, `python -B apps/codestyle/tests/test_scoped_lint.py`,
  `python -B modules/mod-ascension-compat/tests/client_compat/run.py`, `git diff --check`.

## Appendix: AzerothCore MCP

[`azerothcore/azerothMCP`](https://github.com/azerothcore/azerothMCP) (Python, SSE on port 8080) gives an AI
assistant access to the databases (creatures, SmartAI, quests, conditions…). Wiki/source search is disabled by
default; it is only useful with a filled database. Quick audit of commit `dc62b920`: nothing malicious found, but a
Python `exec()` sandbox enabled by default, read-only mode enforced by query prefix only, and unpinned
dependencies. If used: `ENABLE_SANDBOX=false`, a `SELECT`-only MySQL user without `acore_auth` access, isolated
container, pinned commit.

## Useful links

CoA project
- Server: <https://github.com/jealous-sound/azerothcore-wotlk-coa>
- Bug report service: <https://github.com/jealous-sound/coa-bug-report>
- Local kit (workspace tooling, portable client components), cited in `.github/CONTRIBUTING.md`:
  <https://github.com/jealous-sound/coa-local-kit> (returned 404 on 2026-09-15: private or removed)
- mod-playerbots: <https://github.com/jealous-sound/mod-playerbots>
- AzerothCore WotLK with playerbots: <https://github.com/jealous-sound/azerothcore-wotlk-playerbot>
- PR #235 (gameplay test harness): <https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/235>
- PR #243 (Boost build fix): <https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243>
- Client, client patch and repack downloads: shared by the fork author in the project's Discord channel (not linked
  here; game archives must not be redistributed through the repository).

AzerothCore
- Upstream repository: <https://github.com/azerothcore/azerothcore-wotlk>
- Installation overview: <https://www.azerothcore.org/wiki/installation>
- Docker installation: <https://www.azerothcore.org/wiki/install-with-docker>
- Pre-built Docker images (acore-docker): <https://www.azerothcore.org/acore-docker/>
- Linux requirements: <https://www.azerothcore.org/wiki/linux-requirements>
- Linux server setup (configs, client data): <https://www.azerothcore.org/wiki/linux-server-setup>
- Database installation: <https://www.azerothcore.org/wiki/database-installation>
- Keeping the database up to date: <https://www.azerothcore.org/wiki/database-keeping-the-server-up-to-date>
- Networking (realmlist, ports): <https://www.azerothcore.org/wiki/networking>
- Final server steps (accounts, GM): <https://www.azerothcore.org/wiki/final-server-steps>
- Client setup: <https://www.azerothcore.org/wiki/client-setup>
- Common errors: <https://www.azerothcore.org/wiki/common-errors>
- Commit message guidelines: <https://www.azerothcore.org/wiki/commit-message-guidelines>
- AI agentic engineering guidelines: <https://www.azerothcore.org/wiki/agentic-engineering>
- How to test a PR: <https://www.azerothcore.org/wiki/How-to-test-a-PR>
- Stock client data releases: <https://github.com/wowgaming/client-data/releases>
- Discord: <https://discord.com/invite/GyFvXpk7>

Tools
- AzerothCore MCP: <https://github.com/azerothcore/azerothMCP>
- AzerothCore MCP (blinkysc): <https://github.com/blinkysc/azerothMCP>
- MCP via SOAP discussion: <https://github.com/azerothcore/azerothcore-wotlk/discussions/24853>
- Keira3 (database editor): <https://github.com/azerothcore/Keira3>
- umu-launcher (Proton outside Steam): <https://github.com/Open-Wine-Components/umu-launcher>

Ascension on Linux (community)
- Ascension Linux guide (Lutris/Wine, disables `divxtac`): <https://github.com/Elkenniss/ascension-linux-guide>
- Ascension WoW on Arch Linux (GE-Proton, `divxtac` override, `PROTON_DISABLE_XALIA`):
  <https://github.com/Ostekages/Ascension-WoW-on-Arch-Linux>
- Lutris page: <https://lutris.net/games/ascension-wow/>
