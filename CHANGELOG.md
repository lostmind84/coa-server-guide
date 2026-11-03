# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The guide has no versions yet: entries are
grouped by pull request, newest first, and `Unreleased` collects what is merged but not yet listed.

## Unreleased

### Added
- `coa-verify --nopch`: builds without precompiled headers in `build-nopch`, so worktrees at the same sources share
  ccache objects (measured: second worktree 148 s with 94% hits, against 407 s and 41% with PCH; cold build 870 s
  against 762 s).
- `docker/coa-verify-env/Dockerfile`, `scripts/coa-verify` and `docs/tooling/verify-container.md`: a versioned,
  rebuildable image and wrapper for running the server repository's `tools/verify_all.py` on a machine where the
  native build deps (Boost, …) are not installable, replacing per-task ad hoc `docker run` wrappers. `--ram`
  opts into the in-RAM test MySQL without copying secrets into the worktree. See
  [ADR 0018](docs/adr/0018-verify-inside-a-versioned-container-image.md).
- `scripts/install-agent-tools.sh [--check] [--codex]`: links scripts, skills and the triage command, reports missing
  prerequisites and, on another platform than Linux, tells the agent to adapt the setup to its OS and report what it
  could not verify.
- `docs/agent-lessons.md`: technical pitfalls from past runs (preflight, stale harness image, verification cycles, slot
  and harness traps, test data).
- A "Platform" section in `AGENTS.md`: written and tested on Linux, adapt the setup elsewhere.
- `skills/coa-slot-workflow`: the public workflow for slots, preflight, gameplay scenarios, spell obtainability and
  cleanup (the generic part of a former local skill).
- `scripts/coa-obtainable` and `scripts/coa-reference` with `docs/tooling/spell-obtainability.md`: was a spell ever
  obtainable, judged against outside captures. No snapshot is shipped; `coa-reference --update` fetches them.
- `docs/tooling/ram-mysql.md`: the optional in-RAM test MySQL and the guide tools around it.
- `coa-client-lab commands`: every lab command on one line with an example. A test checks it lists each
  dispatcher command.
- `AGENTS.md` and `CLAUDE.md` at the root: where to look, commands, rules and pitfalls for agents.
- `skills/coa-client-check/references/`: probe, measurement and lab-state recipes, read on demand.
- `probe bagitem <bag> <slot>`: the tooltip of the actual item instance sitting in a bag slot
  (`GameTooltip:SetBagItem`), with the same shape as `probe item` plus `bag`, `slot` and `present`. Reads a
  scaled worldforged/dropped copy's own stats, which `probe item <id>` cannot (it only ever shows the item
  template's), fixing a wrong "Requires Level" read (#10599). Allowed through the relay like `item`.
- An optional owner and ETA on the lab lock: `start N --owner NAME --eta-minutes N` (or `COA_LAB_OWNER`/
  `COA_LAB_ETA_MINUTES`) are recorded on the lock line and shown by `status` and the "lab client held" error,
  with a hint that `COA_LAB_INSTANCE=1..9 create-instance` gives a blocked session its own instance instead of
  waiting (#14).

### Changed
- `coa-verify` builds without precompiled headers by default (`build-nopch`; measured second worktree 148 s instead
  of 407 s, cold build 870 s instead of 762 s). `--pch` builds with them in `build`; `--nopch` is now a no-op. A
  worktree built in `build` rebuilds in `build-nopch` unless `--pch` is passed.
- `coa-reference` fetches only over https from a fixed list of hosts (redirect targets included) and refuses a downloaded part whose SHA-256 does
  not match the cache manifest; the platform note tells agents to show adapted commands and to ask before adapting
  destructive ones.
- `install-agent-tools.sh` links only `coa-slot-workflow` and `coa-client-check` into the Claude skills directory; `coa-triage`
  (a command for Claude Code) and the Codex skills `coa-triage` and `coa-fix-issues-batch` (with `--codex`) stay separate.
- README Part 2 moved to `docs/tooling/` (slots and preflight, client lab, relay probes, agent workflow): the README
  drops from 1,259 to about 520 lines and keeps an index. Text moved unchanged; relative links were rewritten.
- `skills/coa-client-check/SKILL.md` shrinks from 338 to about 220 lines; the recipes moved to `references/`.
- The lab script tests run in about 3 minutes instead of 5 (`COA_LAB_PROBE_TIMEOUT=2` in the test environment).
- `docs/tooling/relay-probes.md`/`skills/coa-client-check`: a first item tooltip read (`probe item`, `probe
  bagitem`) can be stale (#10667); re-read after a `/reload` or take a second read before concluding.

### Fixed
- `coa-verify` falls back to precompiled headers, with a note, when the worktree's HEAD is older than server commit
  2a14cd00f5 (#10999): such branches do not build without them (`boss_drakkisath.cpp:94`, missing `SpellInfo.h`).
- `coa-verify` builds hit ccache again: it sets `CCACHE_SLOPPINESS` for the server's precompiled headers (54% of
  calls were uncacheable), `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR` so sibling worktrees share objects, and raises
  `CCACHE_MAXSIZE` from 20G to 50G (`COA_VERIFY_CCACHE_MAXSIZE`, `COA_VERIFY_CCACHE_BASEDIR` override them).
- `coa-worktree-cleanup` refuses up front, with the chown to run, when a directory it must delete is owned by another
  user (a root container's world cache or build dir), instead of failing after the cache schema was dropped; and it
  deletes the published branch with `branch -D`, since `-d` refused it whenever the main checkout's `main` lagged.
- `relay-setup`/`character`'s Go helper now runs with `go test -count=1`: without it, a cached pass after
  `coa-slot reset-db N` could report success without recreating the COALABSOAP account, leaving SOAP at 401.

## Pull requests

- #26 Split `coa-client-check` into a core file and `references/`.
- #25 Skill caveat: confirm a "no effect" dash reading with a positive control.
- #24 `coa-client-lab erase --slot N`, usable while the lab client is stopped.
- #23 Swim recipe corrected (`.tele NAME` is ambiguous in the lab chat); distance-over-a-fixed-hold method.
- #22 `probe state` reports the player's movement (`speed.current`, `swimming`, `falling`, `flying`, `mounted`).
- #21 `probe item` reports `name`, `link`, `quality`, `cached` and `retrieving`.
- #20 `probe perf start [MS]|stop`: client hitches and frame time in the log.
- #19 `probe frame` lists the parent chain and rectangle; `probe actionbar`.
- #18 `coa-slot conf N KEY [VALUE]`: set a config key in a slot's private configuration files.
- #17 `coa-slot classmodel N`; `--since` timestamps in UTC (`Z`) for the restart wait.
- #16 `coa-slot tz N`, `coa-slot warden N on|off`, `coa-slot reseed-test-mysql`, `coa-client-lab camera`.
- #15 Skill: totem packet check with `coa-lab-packets`.
- #14 `goto-spawn`, `character --bag-items`, `coa-lab-mem gameobject`, `revive` retry.
- #13 `coa-client-lab revive`, `erase`, login waits for the glue screen, case-insensitive character selection.
- #12 `erase` checks the character's owner (`pinfo`) and the name before deleting.
- #11 `preflight` warns instead of failing when the slot is behind origin/main.
- #10 `coa-lab-mem gameobject` accepts an entry as well as a GUID.
- #9 `preflight --skip-harness`; first `revive` and `.go` helpers.
- #1 to #8 (from the pull request branch names): lab level 3 relay, memory diagnostics, slot 1 as a dev slot,
  login through the relay, spec and character select fixes, restart keeps the profile, worktree cleanup and
  its `--cache-only` mode.
