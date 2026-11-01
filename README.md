# Conquest of Azeroth (CoA) server on Linux with Docker

Step-by-step guide to run the **Conquest of AzerothCore** server on a Linux PC without installing its build
dependencies on the host, laid out so it can later move to a VPS with few changes. A second part documents the
tooling used to fix and test CoA issues: isolated server slots for parallel work, a preflight check, and a lab copy
of the game client for agents.

- Commands only: [QUICKSTART.md](QUICKSTART.md)
- Automated steps 8–11: [`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh)
- Contributor tooling: [Part 2](#part-2-contributor-tooling)

This is a community guide, not part of the CoA project. It does not ship or link any game archive.

**Status.** Steps 1–13 were first run end to end on 2026-09-15: server up, Ascension data loaded, GM password
changed, client logged in, custom-class character created and **in the world**. Steps 7 and 8 were updated on
2026-09-17 for the client DBC set required since
[#1498](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/1498). The setup script has not had a full run
on a clean machine. In-game gameplay beyond world entry is out of scope. The repository moves fast: when a step
disagrees with the code, the code wins.

| Item | Version of the first walkthrough |
| --- | --- |
| Server repository | [`jealous-sound/azerothcore-wotlk-coa`](https://github.com/jealous-sound/azerothcore-wotlk-coa) `main` at `bb1d48a5f` |
| Repack | `ability-fixes-20260914` (source `126ee7d`) |
| Client patch | `ability-fixes-20260914`, client revision 3 |
| Host | Arch Linux x86_64, Docker with Compose and buildx, uid 1000 |

# Part 1: run a CoA server

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
- First build observed: 1,340 targets in ~392 s on a 16-core machine, 0 errors, 55 warnings. A rebuild after a
  one-file change took ~23 s of compilation thanks to ccache.

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

- Verifies the dump checksum, keeps existing `.env`, `coa.env`, data and module
  configs, never imports over an existing `acore_world`, and does not restart running servers.
- Converts every CRLF update hash found in the checkout (guarded by the Windows hash), runs `dbimport`, fails on a
  non-zero exit, warns on `Reapplying update`, waits for `(worldserver-daemon) ready`.
- Does not patch the client, change the GM password or launch the client.

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

The repository ships scenario tests that run inside a disposable worldserver with copied databases: the scenario
asserts the server's own calculations (spell damage, modifiers, cast times, costs, auras, cooldowns, talents,
pets, loot, quests). `apps/coa-gameplay-test/README.md` documents Windows paths; the Compose service used below is
still in [PR #278](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/278), so the checkout must contain
`apps/coa-gameplay-test/docker/`. From the repository root, after building the server images:

    mkdir -p .cache/coa-gameplay-tests
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      build ac-gameplay-test
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      run --rm --no-deps ac-gameplay-test run apps/coa-gameplay-test/scenarios/frostbolt.json

The first run copies the three databases (about 4.5 minutes here) and keeps the world copy; later runs reuse it
(1.5 minutes for a second scenario). Results go to `.cache/coa-gameplay-tests/<timestamp>/`, the world cache to
`.cache/coa-gameplay-tests/world-cache/`. The running server is not touched. With a server slot, prefix the
command with `coa-slot compose N` and give the compose file an absolute path inside the slot's build clone.

## Known pitfalls

- **Never run `docker compose pull`** (or `./acore.sh docker pull`): locally built images use the same names as
  the official images and would be replaced by versions without the CoA module.
- **Do not run `docker compose up` on all services before steps 8–10**: it creates a stock world database and
  downloads stock client data over the CoA files.
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
  the connection does not come from `127.0.0.1` (the server sees the bridge gateway, e.g. `172.19.0.1`), hence
  `AllowRemoteClients = 1` in step 9. Before
  [PR #261](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/261) (merged 2026-09-15) talent and passive
  modifiers were missing from client tooltips behind Docker; update an older checkout if you see that.
- **Versions must match**: server binary, database, server DBC and client patch go together. A binary older than
  the database causes ACE00004-type errors (`Unknown column ...`).
- **World package shipped in the repository** (`data/coa-world`, `coa-world-20260912`): older than the repack dump.
  If used anyway, `apps/coa-world/world_data.py bootstrap` needs an empty world database, a MySQL 8.4 client
  (`--no-login-paths` is missing from Ubuntu's 8.0 client) and Python 3.11+. Tested: `mysql:8.4` +
  `microdnf install -y python3.12` works.
- **Stock AzerothCore client data**: enough to start the core, but without the Ascension DBC files (empty
  collections, partial CoA content).

# Part 2: contributor tooling

Tools for fixing and testing CoA issues on a Docker setup built with Part 1. They were written for one workstation
and made configurable afterwards: defaults assume the layout of Part 1 (`~/Projects/azerothcore-wotlk-coa`,
`~/CoaServer`, `/srv/coa`). Install them by linking the scripts into your `PATH`:

```bash
git clone https://github.com/lostmind84/coa-server-guide.git ~/Projects/coa-server-guide
ln -s ~/Projects/coa-server-guide/scripts/{coa-slot,coa-client-lab,coa-lab-relay,coa-lab-footprint,coa-lab-mem,coa-lab-packets,coa-worktree-cleanup} ~/.local/bin/
```

## Prerequisites

| Tool | Needed by | Notes |
| --- | --- | --- |
| Part 1 done | everything | a working slot 1 stack, `.env` in the server checkout, `/srv/coa` layout |
| Python 3 | `coa-preflight.py`, `coa-probe-read.py` | imports `apps/coa-dbc/client_dbc.py` from the checkout under test |
| [mpqcli](https://github.com/TheGrayDot/mpqcli) | preflight DBC checks, step 8 | on `PATH`; without it the DBC checks FAIL (`--skip-dbc` skips them) |
| [ConquestOfAzerothGhost](https://github.com/lostmind84/ConquestOfAzerothGhost) + Go | `coa-slot create`, e2e tests | protocol-level bot tests; `coa-slot create` derives each slot's `ghost.env` from the Ghost checkout's `.env` (see the Ghost README) |
| btrfs or xfs | `coa-client-lab create` | the lab copy is a reflink copy of the client and its Wine prefix |
| Hyprland 0.56 (Lua config), gamescope, xdotool, ImageMagick | `coa-client-lab` | Hyprland only for the nested display (`hyprctl eval` on a dedicated workspace); the headless display needs gamescope alone |
| lua5.1 | CoaProbe addon tests | tests only |

## Script configuration

Every default can be overridden with an environment variable:

| Variable | Default | Used by |
| --- | --- | --- |
| `COA_MAIN_REPO` | `~/Projects/azerothcore-wotlk-coa` | `coa-slot` (main checkout, source of `.env`) |
| `COA_GHOST_REPO` | `~/Projects/ConquestOfAzerothGhost` | `coa-slot` |
| `COA_SLOTS_ROOT` | `~/CoaServer/slots` | `coa-slot` |
| `COA_REPACK_DUMP` | `~/CoaServer/repack/CoA-Repack/Database/Clean/databases.sql.gz` | `coa-slot create`, `reset-db` |
| `COA_USER_CLIENT` | `~/CoaServer/client/ascension-live` | `coa-client-lab create` |
| `COA_USER_PREFIX` | `~/Games/umu/coa-client` | `coa-client-lab create` |
| `COA_LAB_ROOT`, `COA_LAB_PREFIX` | `~/CoaServer/client-lab`, `~/Games/umu/coa-client-lab` | `coa-client-lab` |
| `COA_PROTONPATH` | `~/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64` | `coa-client`, `coa-client-lab` |
| `COA_LAB_WORKSPACE` | `9` | `coa-client-lab` |
| `COA_CLIENT_DIR`, `COA_WINEPREFIX`, `COA_LOG` | see `scripts/coa-client` | `coa-client` |

Fixed paths: slot build clones are `~/Projects/azerothcore-wotlk-coa-build-sN`, and slot 1 uses `/srv/coa`.
`coa-preflight.py` takes `--repo`, `--client-data`, `--server-dbc`, `--expected`, `--worldserver` and `--database`
options instead (`--help`).

## Parallel work: server slots

One stack serves one agent at a time: a rebuild or restart by one agent silently invalidates the tests of another.
[`scripts/coa-slot`](scripts/coa-slot) runs up to three isolated stacks side by
side, so up to three agents can fix and test batches at once without a shared server lock.

| Slot | Compose project | Containers | Image tag | Ports auth / world / MySQL / SOAP | Config and logs |
|------|-----------------|------------|-----------|-----------------------------------|-----------------|
| 1 | `azerothcore-wotlk-coa` | `ac-*` | `master` | 3724 / 8085 / 3306 / 7878 | `/srv/coa/etc`, `/srv/coa/logs` |
| 2 | `coa-s2` | `coa-s2-*` | `s2` | 3824 / 8185 / 3406 / 7978 | `~/CoaServer/slots/s2/{etc,logs}` |
| 3 | `coa-s3` | `coa-s3-*` | `s3` | 3924 / 8285 / 3506 / 8078 | `~/CoaServer/slots/s3/{etc,logs}` |

Slot 1 is the original server layout (`/srv/coa`); since 2026-10-26 it is a development slot like the others, no longer the game server. Each slot also has its own database volume, build
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
coa-slot release 2                            # batch done: stops the slot's containers (--keep leaves them running)
```

- `create` copies `/srv/coa/etc` once (Ghost tests edit `worldserver.conf`), seeds slots 2 and 3 from the repack
  dump like `setup-coa-server.sh` (realm port set to the slot's world port, CRLF hashes converted), and writes
  `compose.env`, `compose.override.yml` (container names) and `ghost.env` (ports, DBC path, config path).
- `deploy` takes a branch of the main checkout (worktree branches included, no push needed), a branch of origin or
  a commit. A branch name that exists in the main checkout wins over origin, so deploy `origin/main`, not `main`.
  It refuses a clone with uncommitted changes and writes `branch sha date` to `~/CoaServer/slots/sN/state`.
- SQL applied by one branch stays in the slot's database. Before deploying a branch without it:
  `coa-slot reset-db N` (slots 2 and 3 only).
- `list` shows how long each claim has been held (`[held 12 min]`), so a forgotten claim is visible.
- `deploy N REF` takes 2 to 5 minutes and runs in the foreground until the worldserver is ready: give the
  calling tool a timeout of at least 10 minutes (or run it in the background and wait for it) instead of
  letting a 2 minute default move it out of sight.
- `warden N on|off` (slots 2-4) sets `Warden.Enabled` in the slot's own `worldserver.conf` and restarts the
  worldserver. `coa-lab-mem` and `coa-lab-packets` need it off; `deploy` leaves the setting alone. Slot 1
  shares `/srv/coa/etc` with the live server and is refused.
- `conf N KEY [VALUE]` (slots 2-4) sets `KEY = VALUE` in every file of the slot's private `worldserver.conf` and
  `modules/*.conf` that holds it, then restarts the worldserver; without VALUE it lists where the key is set.
  Use it to turn a module on for a client or Ghost check (`CoALegendaryItems.Enable`, `Ascension.Manastorm.Enable`,
  both `0` by default; the Manastorm key sits in two files and both are set). Restore the value before `release`.
  The gameplay-test harness does not read the slot: for a `verify_all` scenario give it its own copy of
  `/srv/coa/etc/modules` through `modules_config_dir` instead (core `docs/coa/verification.md`).
- `classmodel N [coa|hero|wcr]` (slots 2-4) sets `CoA.ClassModel` in the slot's own `modules/coa.conf` and restarts the
  worldserver; no argument prints it. `AscensionMysticEnchant` zeroes Mystic Scroll drops unless the realm offers
  Mystic altars (`hero` or Warcraft Reborn, and not a wildcard realm), so a scroll or chest loot check on a `coa`
  slot looks empty for that unrelated reason. `coa-client-lab character` still creates CoA classes 12-32 under `hero`
  (checked 2026-11-01). Put the slot back to `coa` before releasing it.
- `tz N [ZONE|off]` (slots 2-4) runs the slot's worldserver in another local time zone through a per-slot compose
  override (`compose.tz.yml`, kept across `deploy`), for mechanics gated on the local hour such as the Sun Cleric's
  `Daytime()` (6:00-18:00 local, read with `localtime_r`). The zone is a POSIX string, `UTC-12` meaning twelve
  hours ahead; no argument prints the current value and `off` restores the container default. It recreates the
  worldserver and only moves what reads local time, not the stored timestamps of the database.
- `reseed-test-mysql [N]` refills the in-RAM test MySQL (`coa-test-mysql`, empty after every container restart)
  from slot N's database (default 1) with `mysqldump | mysql` between the two containers: the root passwords
  never leave them. Takes about a minute. It overwrites `acore_auth`, `acore_characters` and `acore_world`, so
  run it only when no `verify_all` run uses the test MySQL; the `coa_test_*` world caches are left alone.
- `destroy N --yes` (slots 2 and 3, released first) removes containers, database volume, the slot's images and
  `~/CoaServer/slots/sN`, and keeps the build clone.
- Claims are plain files: `~/CoaServer/slots/sN/owner` (created with `noclobber`) and `~/CoaServer/slots/issues.tsv`
  (updated under `flock`). They coordinate agents; they do not block a command typed by hand.
- Resources: a running slot used about 5 GiB of RAM here (worldserver 3.8 GiB, MySQL 1.3 GiB). Builds of different
  slots wait for each other at the compile step because the Dockerfile's ccache mount is `sharing=locked`.

## Preflight: can a test result be trusted?

[`scripts/coa-preflight.py`](scripts/coa-preflight.py) checks, read-only, that a test result on the local server
means something. Run it before reproducing an issue and again after every fetch, rebuild, restart, SQL import,
client patch or DBC install. A FAIL means no test result is trustworthy until it is fixed.

| Check | Fails when |
| --- | --- |
| `git` | the checkout lacks commits of `origin/main` |
| `server` | the running worldserver was not built from the checked-out commit, or is not ready |
| `db` | an SQL update shipped by the checkout is not recorded as applied |
| `client` | a local patch replaced an archive the launcher keeps as `NAME.ORIGINAL` (reported) |
| `dbc` | the server's `dbc/` does not load with the checkout's formats, or differs from the DBC set the installed client loads |

```bash
coa-slot preflight 2                    # against a slot (see below)
python3 scripts/coa-preflight.py --help # standalone, defaults to slot 1
```

Differences that belong to work in progress go in `~/CoaServer/preflight-expected.txt`, one per line:
`<dbc file>  <record id or *>  <note>`. An expected difference that is absent is reported too.

## Client lab for agents

[`scripts/coa-client-lab`](scripts/coa-client-lab) runs a separate copy
of the client so an agent can reproduce client-side issues without touching your client. The lab client runs in a
nested gamescope window (1920x1080) on Hyprland workspace 9; you can watch it there. Keyboard input and screenshots
go through gamescope's own X display, so your focus and mouse are never used. One lab client runs at a time.

```bash
coa-client-lab create                      # once: reflink copy of the client and prefix (near-zero disk space)
coa-slot claim 2 "client check"            # the lab client talks to a claimed slot
coa-client-lab character --slot 2 --character Coalabnecro --race 5 --class 23 \
    --level 20 --learn 704723 --items 9701803   # creates/updates its own dedicated account; prints JSON
coa-client-lab preflight 2                 # server and lab client data must match
coa-client-lab start 2
coa-client-lab login Coalabnecro           # resolves the dedicated account and its password itself
coa-client-lab chat "/say hello"
coa-client-lab screenshot                  # prints the PNG path
coa-client-lab hold w 300                  # hold a key down for milliseconds (walk with w/s, turn with Left/Right)
coa-client-lab mute                        # mute this lab client's audio streams by pid (start does it too)
coa-client-lab probe spell 501281          # ask the CoaProbe addon; prints JSON (ping, spell, item, auras, spellbook, known)
coa-client-lab probe log 20                # the addon's capture of UI errors, system messages and casts
coa-client-lab probe state                 # snapshot of the player and current target together
coa-client-lab probe pkwatch 1618 48       # log the next packets with that opcode (48 bytes each) -- survives /reload
                                           #   replaces the client's own handler for that opcode until the client restarts
coa-client-lab probe pksend 1617 u32:1     # build a packet with the client's own CreatePacket/Put*/Send and send it
coa-client-lab probe pkfind                # where CreatePacket, RegisterPacket, Send and ClearPacket live; pkmeta lists the methods
coa-client-lab probe eval GetRealmName()   # evaluate any Lua expression in the client; values as JSON
coa-client-lab probe evwatch ASCENSION_KNOWN_ENTRY_UPDATED   # log that game event's arguments from now on; survives /reload
coa-client-lab stop                        # warns if your own client changed meanwhile
```

**Sub-second capture (L15, 2026-10-27).** A single `screenshot` call is too coarse for an effect that is
airborne or visible for well under a second (a projectile, a brief cast glow): each call is a fresh dispatch,
and whatever drives this script pays its own overhead between two of them. `screenshot --burst N
[--interval-ms MS] [--dir DIR] [--chat TEXT | --key KEY...]` and `screenshot --video-seconds S [--fps N]
[--dir DIR] [--chat TEXT | --key KEY...]` capture several frames (or a short clip) inside *one* call;
`--chat`/`--key` fire the triggering action first, in that same call, so no second dispatch sits between the
action and the first frame. Both print the output directory (or the clip path) and write `DIR/timing.tsv`
(nanoseconds since epoch: the action, and -- for `--burst` -- every frame's start/end).

```bash
coa-client-lab screenshot --video-seconds 3 --fps 20 --chat "/cast Fireball"   # prints DIR/clip.mp4
coa-client-lab screenshot --burst 10 --interval-ms 100 --key 1                 # prints DIR with frame-000.png...
```

Measured live (slot 2, 2026-10-27, nested gamescope at 1920x1080): `--video-seconds` (ffmpeg x11grab) held a
true, evenly spaced 20fps (50ms/frame, `ffprobe` confirmed `nb_frames=60` over an exact 3.000000s) with the
action-to-capture-start gap around 1.6ms -- well inside the `<=100ms` this was built for. `--burst`
(`magick import` per frame) did not: each frame took roughly 2.5s on this same display, regardless of
`--interval-ms`, so **`--burst` cannot reach sub-second spacing here** -- use `--video-seconds` for that and
extract frames from the clip (`ffmpeg -i clip.mp4 frame-%03d.png`) to inspect one. `--burst` still has a use:
several *regular* screenshots (seconds apart is fine) in one dispatch, or environments where ffmpeg/x11grab
is unavailable. Evidence: `~/CoaServer/client-lab/evidence/l15/` (a caster's hands glowing green through
"Raise: Lesser Skeletal Warrior" (spell 500970), caught across roughly 40 of 60 frames; `--burst`'s own
~2.5s/frame timing from a separate run).

**Warden visibility (L15, 2026-10-27).** `coa-lab-mem`'s own guard (`check_warden_disabled`) hard-refuses
every memory read while a slot's `worldserver.conf` does not have `Warden.Enabled = 0`. `coa-lab-packets`
reads the server's own packet log (`.packetlog` over SOAP) and has no Warden check. A prior session only
learned a slot had Warden on once a `coa-lab-mem` call had already failed. `coa-client-lab preflight N` and `start N` now print the slot's Warden state up front
(`coa-lab-mem warden-status --slot N`, reusing `check_warden_disabled` directly instead of a second parser),
and never block on it -- Warden is the slot's own configuration, reported here, not changed by this tool:

```
warden: off on slot 2 (coa-lab-mem usable)
WARN: slot 4 has Warden.Enabled != 0: coa-lab-mem refuses every memory read on this slot's client (its own
guard, see scripts/coa-lab-mem's docstring) until Warden is off. coa-lab-packets reads the server's own packet
log and has no Warden check.
```

The lab copy drops your accounts, remembered login and caches. After a client patch, recreate it:
`coa-client-lab destroy --yes && coa-client-lab create`. The lab client needs an account and a character on the
slot; `coa-client-lab character` (above) creates or updates one through the Ghost e2e harness in one command
(race/class/level/spec/spells/items) on any slot and refuses to change an existing character's class.
It needs [`scripts/lab-character`](scripts/lab-character) (a Go module driven as `go test`, since the Ghost
harness is built around `*testing.T`) and a Ghost checkout (`COA_GHOST_REPO`, default
`~/Projects/ConquestOfAzerothGhost`); the checkout path is supplied through a generated `go.work` `replace`
at run time, so `scripts/lab-character/go.mod` never hard-codes one user's home.

**`--spec ID` (L14, 2026-10-27).** Ghost's own `SetSpecialization` whispers `.localspec`, which server
commit 2d13ffd73a (#5507, "talk to the client through native Extensions.dll packets only") removed along
with every other `ASC_LOCAL_*` chat command; the whisper is now silently ignored, so that path stopped doing
anything with no error at all. `--spec` instead writes the character's `character_settings` row for
`core.ascension_active_spec` directly (`setActiveSpecialization`, `scripts/lab-character/character_test.go`)
-- the same setting `AscensionCompat.cpp`'s `OnPlayerLogin` still reads on every login to populate the active
specialization and grant its automatic (identity) entries, independent of the native 0x0727 packet #5507
replaced the whisper with. This only *stages* the switch: the actual spellbook sync happens at the
character's next login (the lab client's own `coa-client-lab login`, not `character`'s own session), exactly
like `PlayerSettingsStore::UpdateSetting`'s own REPLACE-based design, which is meant to work for an offline
character. Writing it only once was not enough in practice: `WorldSession::LogoutPlayer`'s own `SaveToDB`
only *queues* a save onto `CharacterDatabase`'s async worker before sending `SMSG_LOGOUT_COMPLETE`, so a
write made right after that packet arrives can still lose a race against that still-pending save and read
back reverted a few seconds later (reproduced live, slot 2, 2026-10-27: one of three characters in a row).
`--spec` logs the session out, then re-writes and re-reads the row until it holds across several checks in a
row before giving up, instead of trusting a single read-back. Read the setting back from
`character_settings` (or, once logged in through the lab client, `coa-client-lab probe ca`'s `activeSpec`
field) to confirm it took -- there is no chat command any more to confirm it the way `.localspec` itself once
did. The client-shown half (`probe ca`'s `activeSpec`) ran live for the first time in L14b (2026-10-27,
slot 2): `character --spec 34` on a shared account's character, then `login`, then `probe ca` --
`activeSpec` read back `34`, through the slot's own per-slot relay file (below).

Without `--account`, `character` derives a dedicated account for that one character: `COALAB` plus the
upper-cased character name, truncated to `MAX_ACCOUNT_STR` (17; `src/server/game/Accounts/AccountMgr.h:34`
in the server repo) — `DeriveAccount` in `scripts/lab-character`. The `COALAB` prefix matches the relay's
own `CoA.ProbeRelay.AccountPrefix` default, below, so a dedicated account can be probed too. Its password
is generated once with
`openssl rand -hex 16` and kept at `~/CoaServer/client-lab/secrets/<account lower>.password` (mode 600,
reused on later calls, never printed); `login CHARACTER` reads the same account and password back, so
there is never a character list to pick from. The account refuses to pick up a second, differently named
character (a real second character, or a name collision after truncation) — delete it or use a different
name. Pass `--account NAME` to keep a shared account instead, e.g. for account-wide issues (bank,
account-bound items, collections, the char-select screen itself): `character` then warns, but does not
refuse, once that account holds 2+ characters, since character-select navigation by name only works when
lab-client memory is usable this session (next paragraph). A shared account gets the same password
treatment as a dedicated one (L9): its password is generated once and kept at
`~/CoaServer/client-lab/secrets/<account lower>.password` too, and every `character --account NAME ...`
call re-applies it to the account's real DB password (`e2eharness.EnsureAccount` always rewrites
salt/verifier, even for an account that already existed under a different password), so the secret and the
server never drift apart. `login --account NAME CHARACTER` reads that secret back the same way `login
CHARACTER` does for a dedicated account — no password ever appears on a command line. The older
`login ACCOUNT PASSWORD CHARACTER` form still works for any caller that already has the password another
way.

`login` only ever types credentials onto a screen it has just confirmed is the account-login screen: when
`coa-lab-mem glue` (below) is usable, a read-only memory check of `CGlueMgr::m_currentScreen`; the
pixel-brightness check of the logo area still always runs too, since memory alone cannot tell a clean login
screen from a leftover error dialog layered over it. On a fresh client (nothing attempted since `start`) it
waits (now a bounded poll on memory, capped by `COA_LAB_LOGIN_WAIT`, falling back to the old fixed sleep when
memory is unusable) and checks directly.

On any other state, `login` now recovers **in place**, without restarting the client. In world, it first
tries `kick_via_soap` (`.kick CHARACTER` over the lab SOAP relay, `coa-lab-relay soap`, reading `CHARACTER`
from this session's own `state/lab.json`): confirmed live, slot 2, 2026-10-26, this lands directly on the
login screen (no character-select leg) within `COA_LAB_KICK_WAIT` (8s cap, measured ~3-5s), dismissed by one
XTEST click at the account field's own position (`click_login_dialog_dismiss`) for the resulting "disconnected"
dialog. One retry after `COA_LAB_KICK_RETRY_WAIT` (1s) covers a brief registration race right at the
world-entry boundary; any other kick failure (no SOAP relay set up for this slot, unknown character, SOAP
fault) falls back to the older path: `/camp` (confirmed by a bounded poll for character-select,
`COA_LAB_CAMP_WAIT`, 15s cap), then the character-select "Back" button via XTEST fake input (`xdotool
windowactivate --sync`, then `mousemove --sync` / `click` with no `--window`), confirmed by a bounded poll for
the login screen (`COA_LAB_CHARSELECT_BACK_WAIT`, 10s cap). This is the XTEST form of the click — an earlier
XSendEvent form (`xdotool mousemove --window "$WINDOW" ... click 1`) was tried twice, in two separate
sessions, and failed to reach the login screen when driven inside one `login` process both times (4/4, then
2/2 after fixing a real bug in the second attempt — see
[ADR 0004](docs/adr/0004-login-driven-by-memory-read-glue-state.md)), even though the exact same XSendEvent
click succeeded every time it was run as a separate, external command against the same window. The XTEST form
reached the login screen 4/4 driven in-process in that session (XSendEvent's own exact failure mode) — see
[ADR 0005](docs/adr/0005-in-place-login-recovery-via-xtest-click.md). `restart_client` (stop then start on the
same slot, same instance/profile/resolution) is kept as the final fallback whenever none of the above confirms
its result within its bound, or memory is unusable at all — unchanged from
[ADR 0003](docs/adr/0003-login-trusts-only-provable-screen-state.md); `coa-client-lab stop && start N` still
reaches the same clean state manually, if needed. Measured live, slot 2, 2026-10-26: in-place switches between
two in-world dedicated accounts landed the kick 13.5-13.8s whenever it confirmed (repeatedly reproduced);
`/camp`'s own completion time varied widely under this task's heavy test load (2.6s, ADR 0005, up to 60s+
observed once), so a kick miss falls through to the same ~42-46s band the restart path has always measured —
see [ADR 0007](docs/adr/0007-soap-kick-replaces-camp-for-in-world-recovery.md) for the full investigation,
including the earlier `/camp`-timeout misdiagnosis and the shared-account (`Memdedi`/`Memtwo`) defect this task
could not fix (blocked by the agent sandbox, not a code gap).

**The client's own login state machine (L11, 2026-10-27).** `coa-lab-mem glue` also reads ten
`CGlueMgr` statics (`m_loginResult`, `m_loginState`, `m_lastLoginResult`, `m_lastLoginState`,
`m_disconnectPending`, `m_reconnect`, `m_accountName`, `m_displayingQueueDialog`, `m_showedDisconnect`,
`m_serverAlert`; addresses and the `LOGIN_STATE`/`LOGIN_RESULT` enum names are wowdecomp file:line citations
in `scripts/coa-lab-mem`'s own comment) and two new `--until` states, `login-clean` and `login-settled`. Two
real, live-measured limits, not fixed by this session (documented honestly rather than papered over):
`login_state == LOGIN_STATE_FAILED` (5) reliably detects only one of the two triggers for the "You have been
disconnected from the server" dialog — the client's own login attempt rejected (wrong password, already
online, a duplicate-session disconnect during realm-connect) — not the other (an already-in-world client
kicked, by this script or anyone else: measured `login_state == 16` on both a kicked-and-dialog-showing
client and a genuinely clean login screen reached by `/camp` + Back, identically); and `login_state` is
sticky, not reset by dismissing the dialog, so it cannot confirm a dismiss succeeded either (only
`current_screen == "login"` can, the same bar the pre-L11 code already used). `login` dismisses the
detectable case before typing (`dismiss_login_dialog_via_memory`) and the undetectable one unconditionally,
reconfirmed by memory afterward, at the one place that already needed to run unconditionally
(`goto_login_screen_via_memory`'s own entry and in-world-kick branches — `clear_login_dialog_unconditionally`,
proven harmless on a dialog-free screen); after submitting credentials it polls `login-settled` and fails
fast with the client's own `login_result_name` (`LOGIN_DISCONNECTED`, `LOGIN_INCORRECT_PASSWORD`, ...)
instead of waiting out `COA_LAB_REALM_WAIT` on every failure.

`kick_via_soap`'s stderr is no longer discarded, and retries widened from 1 to `COA_LAB_KICK_RETRY_ATTEMPTS`
(4, 1s apart): under a true zero-gap switch this now surfaces the kick's real answer — the `.kick` command's
own usage/syntax text, from `HandleKickPlayerCommand` (`src/server/scripts/Commands/cs_misc.cpp:1410-1418`)
returning `false` with no message when the target does not resolve to a connected player, which
`ns1__executeCommand` (`src/server/apps/worldserver/ACSoap/ACSoap.cpp:140-146`) turns into a SOAP fault
carrying that text — not empty output as reports/l8/l10 described (their own call discarded stderr). This
reads as a short-lived server-side name/connected-flag registration race in the ~1-2s right after the
*target* character's own world entry; the same call always succeeded a few seconds later in every
reproduction this session. Widening the retry closed it at a realistic ~2s operator pace (dedicated-account
proof: 8/8 consecutive switches, 0 restarts) but not under true zero-gap scripted load, where it can persist
well past 4 attempts and, once one login is rejected (`LOGIN_DISCONNECTED`), every subsequent attempt on the
same client connection fails the same way — even for an unrelated account — until the client is restarted;
not established further at the worldserver/socket level (time budget).

`select_character_via_memory` now tells a genuine "never matched while still on character-select" apart from
"the client was disconnected back to the login screen mid-navigation" (return 1 vs. 2, checked each poll
tick): live-reproduced, slot 2, a shared-account switch under sustained load hit the latter (screenshot:
the "disconnected" dialog, mid-`Down`-press) and the pre-L11 code reported the misleading "could not
highlight CHARACTER" either way. `cmd_login` also retries the (separate, expensive) `glue_state` usability
check up to `COA_LAB_GLUE_STATE_RETRY_ATTEMPTS` (3, 1s apart) before falling back to `select_character`
(no name confirmation): live-reproduced once, a single transient `glue_state` miss at this exact point sent
a switch to that fallback, which silently entered the world as the wrong character (asked for `Shareb`, got
`Sharea`) with only a `WARN`, not a failure.

`login`'s CHARACTER argument (both forms) picks that character on the character-select screen by name when
`coa-lab-mem glue` is usable: `select_character_via_memory` presses Down and re-reads the highlighted name from
memory until it matches, bounded by the list's own length, and refuses (dies) rather than entering the world as
an unconfirmed character if it never matches. Proven live on a 2-character shared account: the first character
needed no navigation, the second needed one Down press and matched both times. When memory is unavailable, the
previous behavior is unchanged: the lookup still reports the character's index, but navigation itself falls
back to whatever the client already has highlighted (live on slot 2 the list wraps circularly instead of
clamping at the top, so a fixed Up-then-Down sequence without reading the result back is not reliable; see the
comment on `select_character` in `scripts/coa-client-lab`). This is moot for a dedicated account (nothing to
pick between).

**`RBAC_PERM_INSTANT_LOGOUT` and the same-account in-place switch (L12, 2026-10-27).** `character` now grants
RBAC permission 1 (`src/server/game/Accounts/RBAC.h:52`) to the account it just created or re-applied a password
to, over the lab SOAP relay (`.rbac account grant ACCOUNT 1`); `rbac-grant --account NAME` is the same grant as
a standalone, idempotent command for an account created before this change. Both refuse (warn, not die, for
`character`'s own call; die for the standalone command) any account name that does not start with `COALAB`
— this grant is scoped to lab accounts and never reaches a real player account. Grepping every
`RBAC_PERM_INSTANT_LOGOUT`/`HasPermission(1` use confirmed this permission has exactly one effect:
`HandleLogoutRequestOpcode` (`MiscHandler.cpp:535-536`) calls `LogoutPlayer(true)` immediately instead of
arming the normal 20s delay. `login`'s same-account character switch (new character shares the account
already logged in this session) uses this to skip the login screen entirely: `goto_charselect_via_memory`
logs out to character-select via `/camp` (confirmed by a bounded poll, `COA_LAB_INSTANT_LOGOUT_WAIT`, 8s cap)
without ever reaching the login screen, then `select_character_via_memory` picks the new character by name —
no credential retype, no account-field click, no realm-connect round trip. Any failure along this path (the
account differs from the one already logged in, the logout does not confirm in time, the name is never
highlighted) falls through to the full different-account recovery below exactly as if this had not run.

Measured live, slot 2, 2026-10-27, `Coalabshare`'s `Sharea`/`Shareb`: this path never failed the overall switch
(15/15 live attempts across this session succeeded, whether via the fast path or its fallback) and reached
6.3-8.6s when the fast path landed, against the ~18-37s a full relogin costs. It did not land reliably,
though: only 1 fast switch in roughly every 7-9 attempts. The cause was the previous `login` returning at the
memory `in_world` signal, about 9 s before the in-world UI takes input, so the next `/camp` was typed into the
loading screen and lost. `login` now returns only once the addon answers a relay ping (`COA_LAB_UI_READY_WAIT`,
30 s): zero-gap same-account switches then took the fast path 5/5, 14-15 s each (ADR 0010, addendum).

A zero-gap switch back to a shared account is sometimes disconnected by the server while the character list is
shown (about 1 in 10; cause open). `login` then restarts the client and logs in once more
(`COA_LAB_LOGIN_ATTEMPTS`, default 2): 15/15 mixed switches reached the right character, 13-23 s each, one at
73 s through that retry. After a `.kick`, `login` also waits for the "disconnected" dialog, found by the
colour of its Okay button since memory does not show it, and dismisses it before typing: from a fresh start,
16/16 mixed zero-gap switches, 15 at 14-26 s (ADR 0011, addendum).

A second idea tried and reverted: making the same instant `/camp` the *primary* recovery for a **different**
-account world switch too (ahead of `kick_via_soap`), reasoning that a graceful instant logout would avoid
`kick_via_soap`'s own server-side registration race (previous paragraph). Live, slot 2: `/camp` did reach
character-select quickly (confirmed even with a generous 25s bound, ruling out a mere timeout), but the
Back-click + different-account relogin that follows it then reliably failed (`login_state`
5/`LOGIN_DISCONNECTED`) on every attempt tried — zero gap, a 2s pace, and a ~15s real gap alike; a settle sleep
before the Back click did not fix it. `kick_via_soap`'s own path (straight to the login screen, no
character-select/Back leg) kept working immediately after, in the same session. Root cause not established
(not verified further). Reverted: `goto_login_screen_via_memory`'s world-recovery order is unchanged from L11
(`kick_via_soap` first, old full-length `/camp` as fallback) — the instant permission's only proven, tested use
stays the same-account path above, which never reaches the login screen or clicks Back at all.

**Two more dialogs and a field-clearing bug (L13, 2026-10-27).** Live, slot 2, reproducing a fast different-
account switch sequence (`--account Coalabshare Sharea`, `Coalabres`, `--account Coalabshare Shareb`,
zero-gap): worldserver logs (`Logger.network.kick=4`, `Logger.network=5`, slot 2 only, restored afterward)
showed every switch completing a normal `WorldSocket::HandleAuthSession ... authenticated successfully` then
exactly one `.kick`-driven `kicked with reason: Unknown reason` (`WorldSession.h:562`'s no-reason overload,
reached through the SOAP `.kick` command) — never once the `AddSession_`/`PlayerLoading` same-account refusal
(`WorldSessionMgr.cpp:328`) this had previously been suspected to be. Two client-side bugs, not a server race,
explained what was actually observed:
- A second, custom "Project Descension - Connection Help" popup (this client's own addon, not a Blizzard
  `StaticPopup`) appears on a genuine drop and shares `current_screen == "login"` with a clean screen, same as
  the dialog `click_login_dialog_dismiss` already targets — but it is much larger and its own Okay button sits
  at about (0.697, 0.792) of the window, well outside that point (measured live, 1024x768: (714, 608)), so the
  existing click landed in its body text and never closed it; every later `login` call then degraded or failed
  until it was cleared by hand. `clear_login_dialog_unconditionally` now also clicks this point
  (`click_connection_help_dismiss`); same harmlessness precedent as the first click (confirmed live against a
  dialog-free login screenshot: this point sits in empty background between the Login and Quit buttons).
- `cmd_login` cleared the Username/Password fields with a fixed run of 20 `BackSpace` keys, which does not
  reliably clear a field still holding a *different*, differently-sized account's text from a fast previous
  switch: reproduced live (screen-check.png) as `COALABCOALABRESLABS` after `Coalabres -> Labswitch` — the old
  account's text untouched with the new one's tail appended — an unrecognized account the server/client reject
  outright (`LOGIN_DISCONNECTED` with no corresponding `WorldSocket::HandleAuthSession` line at all, since the
  client never gets that far). Both fields are now cleared with `ctrl+a` then `Delete` instead, which clears
  regardless of the field's prior length or the click's exact cursor position.

Both fixes measurably improved, but did not eliminate, zero-gap different-account switch reliability in this
session: before them, the exact sequence above failed at its very first different-account step; after them,
three full zero-gap reps (9 switches) ran clean before a `kick_via_soap` retry-cadence flake (documented
above: the SOAP relay's own reply can be its usage/syntax text instead of a real kick, on no fixed schedule)
produced another `LOGIN_DISCONNECTED`, this time with no field-clearing or dialog symptom at all — a
pre-existing, already-documented limitation, not newly introduced, and not re-diagnosed further within this
task's time budget. Root cause of the very first disconnect that triggers either popup in the first place
remains unestablished: Server.log and Auth.log carry no timestamps, so a specific failing attempt cannot be
matched to a specific log line among many textually-identical cycles.

Tests: `scripts/tests/coa-client-lab.test.sh`, `python3 -m unittest discover -s scripts/tests -p
'test_*.py'` (covers `coa-lab-mem glue`) and, for the Go module, `go vet ./...` plus the DB-free tests
(`go test -run '^(TestValidateClass|TestCharacterListOrder|TestDeriveAccount|TestDedicatedAccountConflict)$'`).
Design and spike results: [`docs/design/`](docs/design/).

`start` installs the CoaProbe addon ([`addons/CoaProbe`](addons/CoaProbe)) into the lab client. A probe types
`/coaprobe`, then `/reload` so the client writes the answer to its SavedVariables, which
[`scripts/coa-probe-read.py`](scripts/coa-probe-read.py) reads; each probe takes a reload (about 15 seconds,
including a 10-second wait so the reloaded interface accepts input again). Tests:
`lua5.1 addons/CoaProbe/tests/run.lua` and `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
(`scripts/tests/coa-client-lab.test.sh` needs `python3`).

### Headless lab with relay probes

The lab can also run without a window and answer probes in a quarter of a second, through the server instead of
`/reload`. The slot must run a server with the CoA probe relay (`CoA.ProbeRelay.Enable`, in the server repository's
`src/server/coa/CoAProbeRelay*`) and an admin account for SOAP, here `COALABSOAP`, whose password sits in a mode-600
file. Lab accounts must start with `COALAB`. `relay-setup` creates or updates that account itself (each slot has its
own auth DB, so an account made on one slot does not exist on another): it drives the same
[`scripts/lab-character`](scripts/lab-character) Go module `character` uses, at `SEC_ADMINISTRATOR`
(`src/common/Common.h:60` in the server repo; `CoAProbeRelay.cpp` registers `.labprobe`'s `send`/`result` at that
level), with no character created — SOAP only checks the account's username, password and GM level.

```bash
coa-client-lab relay-setup 2 --soap-account COALABSOAP --soap-password-file ~/CoaServer/client-lab/secrets/coalabsoap.password
coa-slot compose 2 restart ac-worldserver   # SOAP and the relay are read at startup
coa-lab-relay soap ".server info"           # checks SOAP before any login
coa-client-lab preflight 2                  # also records pass/fail for the lab descriptor
COA_LAB_PROFILE=minimal coa-client-lab start 2               # 1024x768, low-cost settings, gamescope headless
coa-client-lab login COALAB1 <password> Coalabone            # CHARACTER writes state/lab.json
coa-client-lab probe spell 501281           # now goes through the relay: no /reload, the target is kept
coa-lab-relay probe frame GameTooltip       # the same, directly
coa-client-lab probe errors 5               # the client's own Lua error text and stack (ERROR_HANDLER_DATABASE);
                                            #   a /reload empties it: pass `previous` to read the errors from before the last one
coa-lab-footprint sample --seconds 60       # memory (Rss/Pss) and CPU of this lab client and its wineserver
coa-lab-mem check                           # read-only process-memory diagnostics: object manager, unit/aura state, spell rows
coa-lab-mem glue                            # glue screen state: current screen, in-world flag, char-select index/names;
                                            #   `login` reads this itself (see above) -- useful standalone for debugging it
coa-lab-mem glue --until in-world --timeout 45  # one process polls internally (0.1s) until STATE holds or the
                                            #   timeout; `login`'s own waits use this (see ADR 0006), not a shell loop
coa-lab-mem gameobject ENTRY|0xGUID         # a gameobject's flags, GAMEOBJECT_DYNAMIC (activate/sparkle/...) and state as the
                                            #   client holds them for this player (offsets from UpdateFields.h, validated live 2026-10-31)
coa-client-lab revive [CHARACTER]           # revive a dead/ghost lab character over SOAP (.revive): the client's chat box
                                            #   refuses all input, GM commands included, while dead. Default: last logged-in character
coa-client-lab goto-spawn gameobject|creature --entry ID|--guid ID [--distance YD] [--bearing DEG] [--dz YD]
                                            # stand next to a spawn read from the slot database, facing it (`.go gameobject`
                                            #   lands inside the model); bearing 0 = east, 90 = north
coa-client-lab camera status|reset|pitch up|down MS  # also yaw left|right and zoom in|out: move the third-person camera on
                                            #   its own; every move prints the pitch (-89..89 degrees, applied in bursts: converge
                                            #   by reading it); the angle is saved per character and survives relogs, `reset` undoes it
                                            #   (an underwater or elevated object can then be framed)
coa-client-lab erase CHARACTER [--account A] # delete a throwaway lab character over SOAP (in-game GMs lack the RBAC
                                            #   permission); without --account also its dedicated COALAB account and password file
coa-lab-packets on && coa-lab-packets auras # the server's own packet log: `.packetlog` over SOAP, decoded aura updates
```

- **Relay configuration is per slot (L14b, 2026-10-27).** `relay-setup N` used to write one file,
  `~/CoaServer/client-lab/relay.env`, shared by every slot and every lab instance; a `relay-setup` on one
  slot silently broke another session's relay on a different slot, because the next read anywhere just
  took whatever slot that single file last named. `relay-setup N` now writes
  `~/CoaServer/client-lab/relay/slotN.env` instead, one file per slot, and never touches a pre-existing
  shared `relay.env` -- every reader (`grant_instant_logout_rbac`, `kick_via_soap`, `write_descriptor`,
  `coa-lab-relay soap`) resolves its own slot's file first and falls back to the legacy shared `relay.env`,
  read only, only when that file's own `SLOT` line still matches. An old setup that never reruns
  `relay-setup` keeps working through that fallback; a setup rerun on the new code gets its own file and
  stops competing with every other slot's. See [ADR 0013](docs/adr/0013-per-slot-relay-configuration.md).
- `COA_LAB_PROFILE=minimal` writes `gxResolution` and low-cost CVars (`maxFPS`, `farclip`, `baseMip`, ...) before
  every start and defaults to `COA_LAB_DISPLAY=headless` (gamescope `--backend headless`: no Hyprland window;
  `screenshot` and keyboard input still work). `COA_LAB_DISPLAY=nested` shows it on the workspace again.
  `COA_LAB_WIDTH`/`COA_LAB_HEIGHT` change the size (640x480 was accepted). The default is 1024x768, not 800x600:
  at 800x600 the character pane's Ranged block runs off the bottom of the window (confirmed live, slot 2,
  2026-10-26, level 20 character, `C` key); 1024x768 shows more of it, though the attribute list is a scrollable
  Blizzard frame and even 1280x1024 with a smaller `/console uiScale` did not fit all of it unscrolled (a mouse
  wheel reaches the rest at any resolution). Keep `COA_LAB_WIDTH`/`COA_LAB_HEIGHT` at the same 4:3 ratio: a
  taller-than-4:3 pair (800x720 was tried) letterboxes the whole client, including the login-screen pixel check
  `login` now does (next paragraph).
- Only read-only commands go through the relay (`ping spell item auras spellbook known log state ca frame
  errors`); every relay answer carries `loadId` (changes on each UI load) and the answering `character`.
  **Everything else reloads the UI** — `eval`, `pksend`, `pkwatch`/`pkmeta`/`pkfind`/`evwatch`/`evunwatch` (the
  watches), and any command at all once `COA_LAB_TRANSPORT=reload` forces that path (useful to debug a relay
  answer against the `/reload` one for the same request). This is by design, not an oversight: the relay only
  runs read-only commands (ADR 0006), so `eval` (it can run arbitrary Lua, not read-only) and the watches (they
  install persistent hooks a stateless relay request cannot set up) stay on `/reload`.
  **A `/reload` always costs the client's current UI state** — it tears down and rebuilds every Lua frame:
  an open Spellbook, Character pane or any other frame under test closes, the current target is cleared, and
  the chat window's scrollback is gone (L16, 2026-10-27: a `probe eval` mid-test closed an open Spellbook frame
  the test still needed). None of that is restored afterward. Read UI state you still need with a relay probe
  (`frame`, `ca`, `state`, `spellbook`, `auras`) **before** any `eval`/`pksend`/watch call in the same test, not
  after — there is no "undo" for what the reload just closed.
- `login` waits up to 20 + 25 + 45 s by default (`COA_LAB_LOGIN_WAIT`, `COA_LAB_REALM_WAIT`,
  `COA_LAB_WORLD_WAIT`, each an upper bound, not a fixed sleep: each wait is one `coa-lab-mem glue --until`
  call that ends as soon as memory confirms the real state, or at the bound if memory cannot confirm it).
  Before [ADR 0006](docs/adr/0006-glue-polling-cost-was-the-scripts-own-overhead.md) each wait polled by
  shelling out to a fresh `coa-lab-mem glue` (plus extra `python3` field-parses) every `GLUE_POLL_INTERVAL`
  (2s) tick, and six post-login `/console` sound commands added ~12s more; a fresh client + login measured
  36.5s, an in-world account switch 42.9-49.6s (slot 2, 2026-10-26, see ADR 0004/0005). After ADR 0006 (same
  slot, same profile, 2026-10-26): a fresh client + login measured 17.0s, a successful in-world switch
  8.6-14.9s. Sound is now silenced through `Config.wtf` at every `start`, not through post-login chat;
  `click_charselect_back_xtest`'s pre-existing unreliability (ADR 0005) is unchanged -- a failed click still
  falls back to `restart_client`, whose cost is the client's own relaunch, not glue polling.
- `login CHARACTER` (and `login --account A C`) now confirms CHARACTER is the one actually in world, not just
  that *a* character-select navigation ran (L14, 2026-10-27): `login --account COALABKOX Wrkox` once entered
  the world as the account's other character, Hfkox, with nothing noticing -- `select_character_via_memory`
  already guarded against a *mis-highlight* inside the list, but nothing after it checked the eventual
  in-world name. `wait_ui_ready` (which every successful `login` already calls to confirm the UI is ready)
  now also checks the `character` field every relayed probe answer carries (`addons/CoaProbe/Relay.lua`
  stamps it with the in-world player's own name, independent of whichever name the ping was addressed to) and
  dies if it does not match CHARACTER -- reusing that same ping instead of a second relay round trip. Only
  runs when a relay is configured for this slot (`coa-client-lab relay-setup N`): without one there is no
  reliable, non-visual way to read the in-world name back, same as `write_descriptor` already requires.
  Live end-to-end (L14b, 2026-10-27, slot 2, shared account `COALABSHARE`, characters Sharea/Shareb):
  `login --account COALABSHARE Shareb` / `Sharea` alternated 4 times each (8 switches total), the in-world
  name confirmed correct every time by `probe ping`'s own `character` field. The negative case (the check
  itself failing loudly) was proven without provoking an actual bad login: calling `wait_ui_ready` directly
  with a wrong expected name against a real, correctly in-world session died with `logged in as the wrong
  character: requested WrongCharacterName, the relay reports Sharea is in world`.
- Several lab clients: `COA_LAB_INSTANCE=1 coa-client-lab create-instance` (reflink copy of the base lab and
  prefix), then the same commands with `COA_LAB_INSTANCE=1..9`, one account each. `destroy-instance --yes` removes
  one. Three headless instances ran side by side against one slot.
- Measured footprint and design notes: [`docs/design/client-lab-level3.md`](docs/design/client-lab-level3.md).
- [`scripts/coa-lab-mem`](scripts/coa-lab-mem) and [`scripts/coa-lab-packets`](scripts/coa-lab-packets) read the
  lab client's own process memory and the worldserver's packet log, read only, lab only, and only on a slot with
  `Warden.Enabled = 0` — see [Part 2, "reading the lab client's own state"](docs/design/client-lab-level3.md#part-2-reading-the-lab-clients-own-state)
  and [ADR 0001](docs/adr/0001-lab-client-read-only-diagnostics.md).

### CoaProbe on its own

The probe addon does not need the lab client, the slots or Linux: it answers in any 3.3.5 client, typed by hand.

1. Copy [`addons/CoaProbe`](addons/CoaProbe) (without `tests/`) into `Interface/AddOns/CoaProbe` of your client
   and start the client (an addon folder added while it runs is not loaded by `/reload`).
2. In game, type a request with an id of your choice:
   `/coaprobe r1 spell 706240`, `/coaprobe r2 item 6948`, `/coaprobe r3 auras target`, `/coaprobe r4 spellbook`,
   `/coaprobe r5 known 78`, `/coaprobe r6 log 20`, `/coaprobe r7 state`, `/coaprobe r8 errors 5`. The chat answers
   `COAPROBE r1 ok`.
3. Type `/reload`: the client writes the answers to
   `WTF/Account/<ACCOUNT>/SavedVariables/CoaProbe.lua` (`WTF\Account\<ACCOUNT>\SavedVariables\CoaProbe.lua` on
   Windows).
4. Read one answer as JSON: `python3 scripts/coa-probe-read.py <that file> r1`.

Answers are JSON: `spell` gives name, rank, icon, cost, cast time, range, whether the character knows it and the
tooltip lines; `item` gives the tooltip lines; `auras` gives name, spell id, count, duration, expirationTime, caster
and whether it is harmful for every aura on the unit; `spellbook` lists the known spells with their ids; `known`
answers one spell id; `log` returns the addon's own continuous capture (see below); `state` snapshots the player
and target together; `errors [N] [previous] [locals]` reads the client's own Lua error log
(`ERROR_HANDLER_DATABASE`) directly, no handler install — on this path a `/reload` is also what rotates
`errors.current` into `.previous`, so `errors` and `errors previous` in the same `/reload` describe the errors
from right before and right after it. The addon keeps the last 50 answers and never talks to the server, so it
is safe on a live realm. Limits: it cannot read action bars or 3D models, and a request must not contain `|`.

Installing the addon adds a second SavedVariable, `CoaProbeLog`, written into the same `CoaProbe.lua` file: the
addon continuously captures UI errors ("Not enough rage"), system messages and the player's own casts (with their
failure reason) as they happen, capped at the last 200 entries, independently of any `/coaprobe` request. The `log`
command reads it back the same way as any other answer.

## Skills

[`skills/coa-client-check`](skills/coa-client-check) is a Claude Code skill: it documents the workflow for checking
whether a client-visible symptom (tooltip text or values, an aura shown on the wrong unit, a missing icon or model,
a broken UI element) reproduces, by driving the lab client above and CoaProbe, and returns one of three verdicts
(reproduced / not reproduced / inconclusive) with its evidence. Server-side symptoms belong to the Ghost e2e
harness instead. The skill needs `coa-slot` and `coa-client-lab` on `PATH`, so it is not useful without this guide.

To use it locally, symlink it into Claude Code's skill directory:

```bash
ln -s <path to this repository>/skills/coa-client-check ~/.claude/skills/coa-client-check
```

## Issue workflow for agents

[`agents/coa-triage.md`](agents/coa-triage.md) is the shared workflow this tooling was built for: list the open CoA
issues grouped into batches, then route a selected batch through quick dispositions, source-only work, shared
proof cohorts, individual runtime/client work, and blocked reports. Independent investigation can run in
parallel; mutations to a shared slot, client lab, database, harness image, or worktree are serialized. It expects
a gameplay scenario as the default proof for each issue, Ghost bots for what that harness does not cover (client
packets, experience, RDF/LFG, duels, real relogs, quest-giver interaction), and the client lab for client-only
symptoms. Claiming and closing issues adapt to the permissions your account actually has.

When an agent has pushed the PR of a worktree, it runs
[`scripts/coa-worktree-cleanup`](scripts/coa-worktree-cleanup) `<worktree>` (dry run) and then with `--yes`: the
worktree's world caches leave the in-RAM test MySQL, then the worktree and its local branch go. The script
refuses unpublished, in-use or leased work. When the test MySQL is full mid-batch, `--cache-only` drops only a
worktree's idle world caches and keeps the worktree; the next run copies the world again. See [`agents/git-safety.md`](agents/git-safety.md) for the full
cleanup rule and [ADR 0016](docs/adr/0016-clean-up-worktrees-after-publishing.md).

Claude Code uses the command file directly or through a symlink:

```bash
ln -s ~/Projects/coa-server-guide/agents/coa-triage.md ~/.claude/commands/coa-triage.md
```

Invoke it as `/coa-triage`. With no argument it prints the batch table and stops; `/coa-triage <batch>` works that
batch.

Codex uses the skill adapter in [`skills/coa-triage`](skills/coa-triage). Install it as a user skill so it is
available while Codex is running in the separate server repository:

```bash
mkdir -p ~/.agents/skills
ln -s ~/Projects/coa-server-guide/skills/coa-triage ~/.agents/skills/coa-triage
```

Invoke it with `$coa-triage`; with no batch or issue numbers it prints the table and stops. `$coa-triage crashes`
works that batch. `manual` pauses before each fix; `autonomous` settles by policy what the workflow would otherwise
ask (interpretation, snapshot values, publication) and journals every such decision in
`.agents/plans/<batch>/decisions.md`. The selected batch and all publication and issue-closure rules remain those
in `agents/coa-triage.md` for both platforms.

For an issue-to-PR run that follows the server repository's `coa-fix-issues` rules while scheduling work by
evidence cost, install the personal [`coa-fix-issues-batch`](skills/coa-fix-issues-batch) skill:

```bash
ln -s ~/Projects/coa-server-guide/skills/coa-fix-issues-batch ~/.agents/skills/coa-fix-issues-batch
```

Invoke `$coa-fix-issues-batch <issue numbers or filter>`. With no selection it shows the batch table; `all`
explicitly selects the entire open queue. The maintainer-owned skill in the server repository stays unchanged.

In Claude Code, pair `autonomous` mode with `/goal` for an unattended batch. Its timeout settings are specific to
Claude Code and are not required by the Codex skill.

[`agents/git-safety.md`](agents/git-safety.md) covers the workspace rules a batch misses most expensively: prove a
scenario fails before the fix exists rather than resetting to re-observe it, give each dispatched implementer its
own worktree, never rewrite committed work, and treat a stale harness image or a probabilistic assertion as a
result that lies.

Its first step, the topical batch table, is deterministic and does not need an agent: `scripts/coa-triage-table.py`
keeps a local copy of the open issues in `~/.cache/coa-triage/issues.json`, asks GitHub only for the issues
updated since its last sync (the API's `since` filter: open ones are upserted, closed ones dropped) and prints the
table. The first run fetches everything, about 20 s; later runs take under a second and say on stderr what changed.
Audit reports are grouped by class; the rest go to crashes, then to their class label (`multi-class` when an issue
carries several), then to a class named in the title, then to a keyword theme; issues that carry an assignee are counted
separately so a batch already taken is visible. This table is a stable topic index, not an execution order or a
cost estimate. After the user selects a batch, the workflow makes a compact issue ledger and orders work by
evidence cost: fast dispositions, source-only fixes, shared runtime proof, individual runtime/client proof, then
unclear or blocked reports. It batches deploy/build/preflight cycles at the shared-proof cohort boundary and
publishes ready work without waiting for unrelated items. The 90% time reduction is a target to measure, not a
claim made by the grouping algorithm.

```bash
python3 scripts/coa-triage-table.py            # sync since last run, print the table
python3 scripts/coa-triage-table.py --refresh  # discard the local copy and refetch everything
```

Class labels come from the maintainers and are reliable; the keyword themes and the title-based class fallback are
not, so read those rows as a starting point, not a classification. The cache keeps each issue's labels; a cache
written before labels were kept is refetched in full on the next run.

## Contributing back

- You need write access or a GitHub fork of `jealous-sound/azerothcore-wotlk-coa` (external contributors open PRs
  from their fork): `git remote add fork https://github.com/<user>/azerothcore-wotlk-coa.git`.
- PR body follows `.github/pull_request_template.md`: *Problem and resulting behavior*, *Validation and remaining
  limits*, *Data/source dependencies* (confirm applied SQL is unchanged, no credentials, profiles or game archives).
- `.github/CONTRIBUTING.md`: focused changes; report source checks, builds and in-game tests separately. GitHub
  Actions only runs repository checks, not a server build; PRs from forks may wait for maintainer approval to run.
- Commit/PR title: `type(Scope/Subscope): short description`, imperative, max 50 characters, as in
  `fix(CoA/Chronomancer): implement Displacement pull-and-cleanse`; the repository's
  `.agents/skills/generate-pr-description` skill describes the PR format. Everything in English. Disclose AI
  assistance. Put `Fixes #N` in the PR body so the issue closes on merge.
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
