# Server slots and preflight

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)).

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
[`scripts/coa-slot`](../../scripts/coa-slot) runs up to three isolated stacks side by
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

[`scripts/coa-preflight.py`](../../scripts/coa-preflight.py) checks, read-only, that a test result on the local server
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
