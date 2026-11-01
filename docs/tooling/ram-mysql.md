# In-RAM test MySQL (optional, a large time saver)

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)).

The gameplay stage of `tools/verify_all.py` copies the world database for every run. Putting the test MySQL's data
directory in RAM removes the disk wait: the server repository measured one short scenario at 150 s cold and 60 s warm
on a stock disk MySQL against 41 s and 29 s in RAM (medians, one workstation, 2026-10-25; your numbers will differ).
It is optional and never required: a run against your normal MySQL stays the reference and is judged the same way.

**The authoritative instructions are in the server repository**, `docs/coa/verification.md`, section "Optional: in-RAM
test database": the `docker run` command (a `mysql:8.4` container on `127.0.0.1:3706` with a 12 GB tmpfs data
directory and durability flags turned off), how to seed it, how to point `verify_all` at it with a separate
`--settings` file, the memory to plan for and the several-servers variant. This page only adds what this guide's
tools do around it.

## What to keep in mind

- **It is a throwaway server.** Everything in it is lost when the container stops or the machine reboots, and a crash
  can corrupt it (no binary log, no doublewrite, relaxed flushing). Never point a settings file at a real, shared or
  production database and never reuse another server's root password for it.
- **Secrets stay outside every repository.** Keep the root password, the MySQL client file (`[client]` with `host`,
  `port`, `user`, `password`) and the worldserver config copy whose three `*DatabaseInfo` entries name the container
  in one private directory, for example `~/CoaServer/test-mysql/secrets/` with mode 700 and 600 files. The
  worldserver config copy is the normal one with those three entries changed (and `DataDir` set to your server data).
- **Publish the port on loopback only** (`127.0.0.1:3706`), as in the server repository's command.
- **Plan the memory:** roughly the data directory plus the buffer pool, plus about 5 GB per simulated worldserver
  when you run several gameplay jobs. Keep the standard route on a machine that cannot spare that.

## Tools in this guide

- `coa-slot reseed-test-mysql [N]` refills the container from slot N's database (default 1) with `mysqldump | mysql`
  between the two containers, so the root passwords never leave them. Use it after every container restart (the
  container starts empty). It overwrites `acore_auth`, `acore_characters` and `acore_world` in the container, so run
  it only when no `verify_all` run is using it. The container name defaults to `coa-test-mysql`; `COA_TEST_MYSQL`
  overrides it.
- Each worktree's gameplay runs leave `coa_test_*_world` caches in the container (about 1.3 GB each in the
  measurements above). `scripts/coa-worktree-cleanup <worktree> --yes` drops them with the worktree once its PR is
  published, and `--cache-only` drops only the idle caches of a worktree you keep. Without this the tmpfs fills up
  (see [ADR 0016](../adr/0016-clean-up-worktrees-after-publishing.md) and
  [ADR 0017](../adr/0017-cache-only-cleanup.md)).
- `docker exec coa-test-mysql df -h /var/lib/mysql` shows how full the tmpfs is.

## Limits

This route was set up and measured on one Linux workstation. Docker with tmpfs mounts is what it needs; on other
operating systems the idea carries over but the paths and commands in the server repository's section would need to
be adapted, which has not been tried.
