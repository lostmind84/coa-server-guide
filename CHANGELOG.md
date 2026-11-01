# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The guide has no versions yet: entries are
grouped by pull request, newest first, and `Unreleased` collects what is merged but not yet listed.

## Unreleased

### Added
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

### Changed
- README Part 2 moved to `docs/tooling/` (slots and preflight, client lab, relay probes, agent workflow): the README
  drops from 1,259 to about 520 lines and keeps an index. Text moved unchanged; relative links were rewritten.
- `skills/coa-client-check/SKILL.md` shrinks from 338 to about 220 lines; the recipes moved to `references/`.
- The lab script tests run in about 3 minutes instead of 5 (`COA_LAB_PROBE_TIMEOUT=2` in the test environment).

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
