# Reproducible `verify_all` container

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)).

`tools/verify_all.py` in the server repository needs a C++20 toolchain, CMake, Ninja, Boost, MySQL client
libraries and OpenSSL to configure and build the worldserver. On at least one workstation these are not
installable natively (CMake reports `Could NOT find Boost` on that distribution's packages), so verification
runs inside a Docker image instead: `docker/coa-verify-env/Dockerfile` in this guide, built as
`coa-verify-env:24.04`. This page documents that image, the `coa-verify` wrapper that runs `verify_all.py`
inside it, and the steps to reproduce the whole setup on a new PC. See
[ADR 0018](../adr/0018-verify-inside-a-versioned-container-image.md) for why a container image instead of fixing
the native host deps.

Before this page existed, agents on this workstation reused one unversioned image built by hand and wrote a new
ad hoc `docker run` wrapper per task. `coa-verify-env/Dockerfile` and `scripts/coa-verify` replace both: the
image is versioned (rebuildable from this repository, tagged), and the wrapper is one script instead of a new
shell snippet per worktree.

## Setup on a new PC

1. **Build the image** (from this guide's checkout):

   ```bash
   docker build -t coa-verify-env:24.04 -f docker/coa-verify-env/Dockerfile docker/coa-verify-env
   ```

   This installs the exact Ubuntu 24.04 package set `verify_all.py`'s build and test stages need: a C/C++
   toolchain, ccache, CMake, Ninja, clang, git, the MySQL client and `libmysqlclient`/`libmysql++` dev headers,
   `libboost-all-dev`, OpenSSL, readline, zlib, bzip2, ncurses, lzma and Python 3 (symlinked to `python`, since
   `verify_all.py` invokes `python` for some sub-steps). No source is copied into the image: it is a toolchain
   layer only, built once per machine (or whenever the Dockerfile changes) and reused by every worktree.

2. **Create the ccache directory** the container will reuse across runs and worktrees:

   ```bash
   mkdir -p ~/.cache/coa-verify-ccache
   ```

   `scripts/coa-verify` creates this directory itself if missing; the explicit `mkdir` is only needed if you
   want it to exist before the first run for another reason (checking free space, for example).

3. **Server data and configs.** `scripts/coa-verify` mounts `/srv/coa/server-data` and `/srv/coa/etc` read-only
   into the container when they exist, and sources `/srv/coa/coa.env` as the container's environment file when
   present. These are **not** part of this guide's install steps; they are the same server data (`dbc/`, …),
   module configs and environment file Part 1 and `docs/tooling/slots-and-preflight.md` already set up for
   running a server. Point `COA_SRV_COA` at a different root if your layout differs.

4. **(Optional) in-RAM test MySQL**, for a faster gameplay stage: see
   [`docs/tooling/ram-mysql.md`](ram-mysql.md) in this guide for what the tools around it do, and the
   authoritative setup (the `docker run` command for the `mysql:8.4` container, seeding, memory planning) in the
   server repository's `docs/coa/verification.md`, "Optional: in-RAM test database". `coa-verify --ram` only
   consumes this container; it does not create or seed it.

   The secrets layout `coa-verify --ram` expects (see `docs/tooling/ram-mysql.md`'s "Secrets stay outside every
   repository"): a private directory, by default `~/CoaServer/test-mysql/secrets/` (mode 700), holding
   `worldserver.ram.conf` (a worldserver config copy whose three `*DatabaseInfo` entries point at the container
   on `127.0.0.1:3706`) and `ram-client.cnf` (a MySQL `[client]` file with that container's root credentials).
   Override the directory with `COA_TEST_MYSQL_SECRETS` if yours lives elsewhere.

5. **First run**, from a worktree of the server repository (or pass `--worktree`):

   ```bash
   coa-verify --plan                     # resolves settings and stages without running anything
   coa-verify --stages source            # the fast source checks, no build
   coa-verify --stages build,gameplay --scenario primalist-everlasting-rage
   coa-verify --ram --stages gameplay --scenario primalist-everlasting-rage   # against the in-RAM test MySQL
   ```

   Every argument that is not `--worktree`, `--ram`, `--pch` or `--nopch` passes straight through to
   `tools/verify_all.py`, so `docs/coa/verification.md` in the server repository (stage selection, `--settings`,
   exit codes, `report.json`) remains the reference for everything past the container itself. Before a PR, also run
   `coa-verify --stages source --base origin/main` per that repository's `AGENTS.md`; run every stage only when a
   full verification is explicitly requested.

## What `coa-verify` does

`scripts/coa-verify` (see its module docstring for the exact option list) is a thin, versioned replacement for
the ad hoc `verify.sh` wrappers agents used to write per task:

- Runs against the current directory, or `--worktree DIR`. The main checkout (the repository that owns the
  `.git` directory a linked worktree points into) is derived with `git -C DIR rev-parse --git-common-dir`, so a
  worktree's `.git` file pointing elsewhere is resolved automatically and both the main checkout and the
  worktree are mounted when they differ.
- Mounts the main checkout and the worktree at their own host paths (so absolute paths inside the container
  match the host, which `verify_all.py`'s settings and reports expect), the ccache directory at `/ccache`, and
  `/srv/coa/server-data` and `/srv/coa/etc` read-only when present.
- Sets `HOME=/tmp` (the container has no home directory of its own for the caller's uid), points
  `CCACHE_DIR`/`CMAKE_*_COMPILER_LAUNCHER` at the mounted ccache, trusts the mounted repositories for git
  (`safe.directory=*`), and runs as the caller's uid:gid so nothing it writes becomes root-owned.
- Lets ccache reuse objects across builds and worktrees: the server builds with precompiled headers
  (`USE_COREPCH`/`USE_SCRIPTPCH`), which ccache refuses without `CCACHE_SLOPPINESS=pch_defines,time_macros,
  include_file_mtime,include_file_ctime`; `CCACHE_BASEDIR` (default: the common parent of the main checkout and the
  worktree, `COA_VERIFY_CCACHE_BASEDIR` overrides it) and `CCACHE_NOHASHDIR=1` make paths in sibling worktrees
  hash alike. `CCACHE_MAXSIZE` defaults to 50G (`COA_VERIFY_CCACHE_MAXSIZE`): 20G filled up on this workstation.
  Measured 2026-11-03 at server 042b38a436 with a fresh cache: 54% of compiler calls were uncacheable
  ("Could not use precompiled header") and the hit rate was 8.7% before; after, a cold worktree built in 925 s
  with no uncacheable call and a second worktree of the same commit in 497 s with 41% hits (each worktree still
  builds its own precompiled headers, so the files that use them miss).
- Several gameplay scenarios in one run share one worldserver boot: pass them all to one `--scenario`
  (`--scenario A B C`) instead of one run per scenario.
- Refuses immediately, printing the `docker build` command above, when `COA_VERIFY_IMAGE` (default
  `coa-verify-env:24.04`) is not present locally — never an unexplained docker error.
- With `--ram`: checks the in-RAM test MySQL container (`COA_TEST_MYSQL`, default `coa-test-mysql`) is running
  (`docker ps`) and refuses with a reseed hint if it is not; mounts the secrets directory
  (`COA_TEST_MYSQL_SECRETS`) read-only at its own path instead of copying the worldserver config and MySQL
  client file into the worktree; creates the worktree's `env/dist/etc/modules` (the `server_modules_dir`
  `verify_all.py` expects to exist); writes a `--settings` JSON pointing at all of this into the worktree's
  gitignored `.cache/coa-verify/settings.ram.json`; and appends `--settings <that file>` unless the passthrough
  arguments already name one.

All of the above is overridable by environment variables (`COA_VERIFY_IMAGE`, `COA_VERIFY_CCACHE_DIR`,
`COA_SRV_COA`, `COA_TEST_MYSQL`, `COA_TEST_MYSQL_SECRETS`), the same convention as `COA_MAIN_REPO` and
`COA_TEST_MYSQL` elsewhere in this guide's scripts; the defaults match this workstation's layout.

## Pitfall: never share a host CMake cache with the container

A build directory's `CMakeCache.txt` records absolute toolchain paths (compiler, sysroot, found libraries) from
wherever it was configured. Reusing a build directory a native host build (or a different container image)
already configured, inside this container, re-finds a mix of host and container paths and fails or silently
links against the wrong libraries. Give the container its own build directory — a fresh one, or one only ever
configured inside this same image — never a `build_directory` a host build has touched. The same applies in
reverse: do not configure a build directory inside the container and then try to build it natively.

## Precompiled headers: off by default, `--pch` to turn them on

`coa-verify` builds without precompiled headers by default: it configures a separate `build-nopch` directory with
`-DNOPCH=1` (the server builds this way since server PR #10999). Without precompiled headers every object depends
only on the sources, so a worktree reuses almost everything another worktree compiled at the same sources; with them,
each worktree builds its own `.gch` and every file that uses it misses the cache. `--pch` builds with precompiled
headers in `build`, `verify_all.py`'s own defaults; `--nopch` is still accepted and changes nothing. A `--settings`
file of your own is passed through untouched, so its `build_directory` and `cmake_args` decide.

Branches older than server commit 2a14cd00f5 (#10999, which added the includes this mode needs) do not build
without precompiled headers (for example `boss_drakkisath.cpp:94: invalid use of incomplete type 'const class
SpellInfo'`). `coa-verify` checks `git merge-base --is-ancestor 2a14cd00f5 HEAD` in the worktree: when the commit is
missing it prints a note and builds with precompiled headers in `build`, as `--pch` would; an explicit `--nopch`
keeps the default mode and warns instead. Rebase such a branch on main to get the shared cache.

The two modes build in different directories: a worktree already built in `build` (before this default, or with
`--pch`) rebuilds from scratch in `build-nopch` on its next default run. Pass `--pch` to keep using that build, for
example for a `--stages gameplay` run without a build stage.

Measured on this workstation on 2026-11-03 at server 2a14cd00f5, `--stages build`, an empty ccache per mode, two
fresh worktrees each (one run per cell); these numbers decided the default:

| Mode | First worktree (cold cache) | Second worktree (same commit) | Cache used |
|---|---|---|---|
| `--pch` | 762 s, 0/1895 hits | 407 s, 778/1895 hits (41%) | 4.0 GiB |
| default (no PCH) | 870 s, 0/1890 hits | 148 s, 1785/1890 hits (94%) | 2.1 GiB |

The gain assumes worktrees close to the same commit; sources that differ recompile in both modes.

### Known unreproduced failure: compiler segfault

The first cold no-PCH build of that measurement stopped after 216 s on a crash of the compiler itself, not a source
error:

```
FAILED: src/server/coa/CMakeFiles/coa.dir/AscensionCallboardCache.cpp.o
../src/common/Collision/Models/GameObjectModel.h:61:72: internal compiler error: Segmentation fault
```

The same tree, rebuilt from an empty `build-nopch` and an empty ccache, passed; the cause is unknown (no kernel
log entry was found). If it happens again: rerun the build once before suspecting the change, and if it recurs, note
the object, the free memory and the machine load, and report it to the guide/lab owner so the cases can be compared.

## Timing

Measured on this workstation on 2026-11-02: the `build` stage of a fresh worktree (new build directory, ccache
directory already in use by earlier runs) took 3498 s, about 58 minutes, inside this image; one short gameplay
scenario against an existing build and the in-RAM MySQL took 53.5 s. Later builds of the same worktree only
recompile what changed. Your numbers depend on CPU, disk and how warm `~/.cache/coa-verify-ccache` is; treat these
as one data point, not a guarantee, the same way `docs/tooling/ram-mysql.md` treats its own timing figures.

## Limits

This route was set up and measured on one Linux workstation with Docker. The image and wrapper assume a Linux
container host; on another OS the idea (a versioned toolchain image instead of native host deps) carries over
but the mount paths, `uid:gid` handling and `/srv/coa` layout would need adaptation, which has not been tried
(see "Platform" in [`AGENTS.md`](../../AGENTS.md)).
