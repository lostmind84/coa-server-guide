# Build server: produce and ship CoA releases

The build server compiles the CoA fork for the production host and sends it everything the game server needs to
install or update itself. The production side is described in [prod-server.md](prod-server.md). The build server also keeps a light
copy of the player data ([backup.md](backup.md)). For a single machine
that builds and runs the server itself, see [../NATIVE-UBUNTU.md](../NATIVE-UBUNTU.md). Releases with bots
(mod-playerbots): [playerbots-build.md](playerbots-build.md).

Status: the whole chain (build in the container, ship over SSH with rsync, first deployment, then an update from the
repack revision `b3717c137` to `47dd22ffe`) was run end to end on 2026-09-27 with two Ubuntu 26.04 containers standing
in for the two hosts. The build host itself was not an Ubuntu 24.04 machine; only Docker, git, rsync and ssh are used
on it.

## Why a container

The production host runs Ubuntu 26.04. A binary built on Ubuntu 24.04 links against Boost 1.83 and other 24.04
libraries and does not start on 26.04 (Boost 1.90, `libmysqlclient24`, …). The build therefore runs inside an
`ubuntu:26.04` container; the build host OS does not matter.

## What a release contains

```
releases/<YYYYMMDD-HHMM>-<sha7>/
  RELEASE.md     notes for the production admin (generated)
  release.env    RELEASE_ID, REVISION, PREVIOUS_*, BUILD_OS=ubuntu-26.04, DATA_VERSION, BUILT_AT
  bin/           authserver, worldserver
  etc/           *.conf.dist and modules/*.conf.dist (templates only, never live settings)
  source/        data/sql/{base,updates,archive,custom} and modules/*/data/sql
  SHA256SUMS     checksums of every file above
```

`source/` is required: worldserver applies database updates at startup by reading these SQL files
(`SourceDirectory`), and compares them with the `updates` table of each database. Without them the production
database is never updated. `data/sql/old` is left out (never read by the updater).

The binaries are built with `CMAKE_INSTALL_PREFIX=/opt/coa/current` and `CONF_DIR=/opt/coa/etc`: worldserver looks
for `worldserver.conf` and `modules/*.conf` in `/opt/coa/etc` on production. Changing the production layout means
changing these two values in `coa-build-release.sh`.

Client data (`dbc`, `maps`, `vmaps`, `mmaps`, `Cameras`, 3.8 GB) is not in the repository and is not rebuilt. It
comes from a repack release and is shipped separately, only when its version changes (`DATA_VERSION`).

`RELEASE.md` lists, relative to the last release shipped to production:

- the commits;
- the new SQL update files (worldserver applies them at startup);
- **modified SQL update files**: an already applied file whose content changed is re-applied by worldserver; the
  admin must check it is safe to run twice;
- moved SQL files with unchanged content (not re-applied: the updater matches applied files by name);
- removed SQL files;
- configuration keys added to or removed from the `.conf.dist` templates;
- a client data change, when `DATA_VERSION` differs.

## One-time setup

Packages (Ubuntu 24.04): `sudo apt-get install -y docker.io git rsync openssh-client`, and add the build user to the
`docker` group.

```bash
sudo mkdir -p /srv/coa-build && sudo chown "$USER": /srv/coa-build
cd /srv/coa-build
git clone https://github.com/jealous-sound/azerothcore-wotlk-coa.git src
```

Keep a full clone (not `--depth 1`): `RELEASE.md` is computed from the history between releases. Do not enable
`core.autocrlf`: the production updater hashes the bytes exactly as they are in the repository.

Builder image, from the guide's `scripts/` folder:

```bash
docker build -t coa-builder:26.04 -f scripts/coa-builder.Dockerfile scripts/
```

Rebuild it (same command, add `--pull`) to pick up Ubuntu security updates; production must then run the same
package versions (`apt-get upgrade` there too).

Client data, from the repack (`CoA-Repack/Data`):

```bash
echo main-20260919-b3717c137 > /srv/coa-build/DATA_VERSION        # repack release id (RELEASE.json "releaseId")
mkdir -p /srv/coa-build/data
rsync -a CoA-Repack/Data/ /srv/coa-build/data/main-20260919-b3717c137/
```

Copy `scripts/coa-build-release.sh` and `scripts/coa-ship-release.sh` to the build host (e.g. `~/bin`).

SSH: the build user needs key-based access to the production service account (`coa@prod`), and `rsync` must be
installed on both hosts.

## Build a release

```bash
coa-build-release.sh                 # origin/main
coa-build-release.sh <tag|sha>       # any other revision
```

Output: `/srv/coa-build/releases/<id>/`, and the link `releases/latest`. The CMake build tree
`/srv/coa-build/build` is kept between runs, so later builds are incremental. Logs: `build/{cmake,make,install}.log`
(warnings are expected there). Full build time in the test: about 5 minutes on 32 threads.

Environment: `COA_BUILD_ROOT` (default `/srv/coa-build`), `COA_BUILDER_IMAGE` (default `coa-builder:26.04`).

Read `releases/latest/RELEASE.md` before shipping. A **modified SQL updates** section needs an answer before the
release goes out (see [Modified SQL updates](#modified-sql-updates)).

## Ship a release

```bash
coa-ship-release.sh latest coa@prod.example
```

1. If `/opt/coa/data/<DATA_VERSION>` is missing on production, send `data/<DATA_VERSION>` first (to a `.partial`
   folder, renamed when complete).
2. Send the release to `/opt/coa/releases/<id>/` with `--link-dest` on the newest complete release there: unchanged
   files are hard-linked, only changed files travel.
3. Create `.complete` in the remote release folder last. Production ignores a release without it.
4. Point `releases/shipped` at this release: the next `RELEASE.md` is computed against it.

Then tell the production admin the release id; everything they need to know is in its `RELEASE.md`.

Environment: `COA_PROD_ROOT` (default `/opt/coa`), `COA_DATA_SOURCE` (default
`/srv/coa-build/data/<DATA_VERSION>`).

## New client data (new repack or client patch)

1. Put the new `Data` folder in `/srv/coa-build/data/<new-version>/`.
2. Write `<new-version>` to `/srv/coa-build/DATA_VERSION`.
3. Build and ship: `RELEASE.md` says **Client data changed**, the ship script sends the new folder, and the deploy
   script switches `/opt/coa/data/current` to it.

Players need the matching client patch at the same time.

## Modified SQL updates

Worldserver re-applies an already applied update file whose SHA-1 changed (`Updates.Redundancy = 1`, the default).
Seen in this fork: files re-committed with CRLF line endings, and regenerated data files. Before shipping, check
each listed file:

- only line endings or comments changed: harmless if the SQL is idempotent (`DELETE` then `INSERT`, `REPLACE`), else
  tell the admin to record the new hash instead (see `coa-fix-windows-hashes.sh` in prod-server.md);
- real changes: the re-run is intended; make sure it can run on a database that already has the old version.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `image coa-builder:26.04 missing` | build the image (one-time setup) |
| `DATA_VERSION missing` | create `/srv/coa-build/DATA_VERSION` |
| build fails | `grep -m20 error /srv/coa-build/build/make.log`; after a big upstream change, delete `/srv/coa-build/build` and rebuild |
| files in `build/` owned by root | the container runs as the calling user; a root-owned tree comes from an older manual run, delete it |
| ship fails half way | run it again: rsync resumes, `.complete` is only written at the end |
