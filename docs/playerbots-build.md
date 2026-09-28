# Build server: releases with mod-playerbots

[mod-playerbots](https://github.com/Zyth45/mod-playerbots/blob/coa/README_COA.md), branch `coa`, adds bots of the
CoA classes. This page covers what changes on the build server ([build-server.md](build-server.md)). The production
side, including sizing for 2000 bots, is in [playerbots-prod.md](playerbots-prod.md).

Status: run on 2026-09-28 with the scripts of this repository, the core at `d2c61f17c` and the module at `f765cbb8`
then `46e3d5f8`, in the `coa-builder:26.04` container; the release was deployed on an Ubuntu 26.04 container standing
in for production (see playerbots-prod.md). Not tested: shipping over SSH (unchanged by the module).

## Why the build server is needed

The module is C++ compiled into `worldserver`, not a plugin loaded at runtime. When CMake finds
`modules/mod-playerbots`, it also compiles the core's database layer with `MOD_PLAYERBOTS` (the `acore_playerbots`
connection pool and its updater, `modules/CMakeLists.txt`). A release built without the module has no bots, whatever
the production configuration says. Production never compiles, so the bots can only come from a release built here.

## One-time setup

```bash
cd /srv/coa-build/src/modules
git clone --branch coa https://github.com/Zyth45/mod-playerbots.git mod-playerbots
```

The core's `.gitignore` ignores `modules/*`, so `coa-build-release.sh` checking out a new core revision leaves the
module alone. Nothing else changes: the next `coa-build-release.sh` run configures CMake again and picks the module up.

Which module revision goes with which core revision is in the module's README ("Which versions go together"): the
`coa` branch follows jealous-sound's `main` from `b3717c1` onwards.

## Build and ship

Same commands as without the module:

```bash
coa-build-release.sh
coa-ship-release.sh latest coa@prod.example
```

A full build with the module, from an empty build tree, took 10 minutes in the test (32 threads, on a workstation
busy with other work). What the module adds to a release:

| Where | What |
| --- | --- |
| `bin/worldserver` | the bots |
| `etc/modules/playerbots.conf.dist` | the module's settings template |
| `source/modules/mod-playerbots/data/sql/` | 74 MB of SQL: `playerbots/` for `acore_playerbots`, `world/` and `characters/` applied to the core databases |
| `release.env` | `MODULES="mod-playerbots=<sha>"`: the module revision built |
| `RELEASE.md` | an **External modules** section |

The whole release was 1.6 GB in the test. `coa-ship-release.sh` hard-links unchanged files, so only what changed
travels.

`source/` matters here too: worldserver creates and updates `acore_playerbots` from
`<SourceDirectory>/modules/mod-playerbots/data/sql/playerbots/`, and applies `world/` and `characters/` as module
updates of the core databases.

## Updating the module

```bash
git -C /srv/coa-build/src/modules/mod-playerbots pull --ff-only
coa-build-release.sh
```

The module is built at whatever revision is checked out; `coa-build-release.sh` never fetches it. To pin a revision:
`git -C /srv/coa-build/src/modules/mod-playerbots checkout <sha-or-tag>`. The script stops with
`… has uncommitted changes` if the module folder holds local edits, because such a release could not be rebuilt.

In `RELEASE.md`, the **External modules** section lists, relative to the last release shipped:

- `New in this release`: the first release with this module; worldserver creates its tables at the first start;
- `Unchanged`;
- otherwise the module commits and its new, modified and removed SQL files. A **modified** SQL file is re-applied by
  worldserver when it was already applied, like a core update (see
  [Modified SQL updates](build-server.md#modified-sql-updates)); files under `playerbots/base/` are only used to fill
  an empty `acore_playerbots` and are not re-applied.

A module update often adds settings: they show up under **Configuration keys** in `RELEASE.md`
(`modules/playerbots.conf.dist: …`).

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| build fails in `modules/mod-playerbots` | the module and core revisions do not match: check the module README, pull the module or build an older core revision |
| `… mod-playerbots/ has uncommitted changes` | `git -C …/mod-playerbots status`; commit the change to a branch of your own or `git checkout -- .` |
| `Previous revision … is not in the local clone` in `RELEASE.md` | the module history was rewritten upstream; compare the two revisions by hand before shipping |
