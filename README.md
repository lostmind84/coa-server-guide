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

Linux only: on Windows, macOS or WSL the tools below do not run (see "Platform" in [`AGENTS.md`](AGENTS.md)).
`scripts/install-agent-tools.sh --check` lists what your machine lacks and `scripts/install-agent-tools.sh` links the
tools, skills and the triage command into place.

Each page below is self-contained; agents should start from [`AGENTS.md`](AGENTS.md) and open only the page
they need.

| Page | Covers |
|---|---|
| [Server slots and preflight](docs/tooling/slots-and-preflight.md) | Prerequisites, script configuration, `coa-slot` (parallel isolated servers), `coa-preflight.py` (can a test result be trusted?) |
| [Client lab for agents](docs/tooling/client-lab.md) | `coa-client-lab`, the lab client copy, characters, probes, screenshots, camera, `goto-spawn`, memory and packet tools |
| [Headless lab, relay probes and CoaProbe](docs/tooling/relay-probes.md) | The server relay (`relay-setup`), `COA_LAB_PROFILE=minimal`, the in-client addon on its own |
| [Skills, issue workflow and contributing](docs/tooling/agent-workflow.md) | `coa-client-check`, `coa-triage`, worktree cleanup, contributing back, the AzerothCore MCP, useful links |
| [Decisions](docs/adr) | One ADR per decision about the lab tooling |
| [Changelog](CHANGELOG.md) | What changed, by pull request |
