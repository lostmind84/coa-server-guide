# AGENTS.md

Guide and tooling for running a CoA (Conquest of Azeroth) server in Docker, plus the parallel-slot and client-lab
scripts agents use to test it. Read this file first; open `README.md` only for the section you need.

## Where to look

| Question | Read |
|---|---|
| Install or run the server from scratch | `QUICKSTART.md`, then README parts 1 to 13 |
| Parallel test slots (`coa-slot`) | README "Parallel work: server slots", `scripts/coa-slot help` |
| Is a test result trustworthy? | README "Preflight", `scripts/coa-preflight.py` |
| Driving the game client (`coa-client-lab`, CoaProbe) | `skills/coa-client-check/SKILL.md` and its `references/`, README "Client lab for agents" |
| Why a lab tool works the way it does | `docs/adr/` (one decision per file, never rewritten) |
| Issue queue workflow | `agents/coa-triage.md`, `agents/git-safety.md` |
| Backups, restore, production | `docs/backup.md`, `docs/restore.md`, `docs/prod-server.md` |

`scripts/coa-client-lab commands` prints every lab command with one example; `--help` prints the full usage.

## Layout

- `scripts/coa-slot`, `coa-client-lab`, `coa-lab-mem`, `coa-lab-packets`, `coa-lab-relay`, `coa-lab-footprint`,
  `coa-preflight.py`, `coa-worktree-cleanup`: the agent tooling (symlink them into `~/.local/bin`).
- `addons/CoaProbe/`: the in-client addon (`Commands.lua`, `Relay.lua`, `Events.lua`) and its tests.
- `skills/`: Claude Code skills (`coa-client-check`, `coa-triage`, `coa-fix-issues-batch`); `agents/`: shared workflows.
- `docs/adr/`: decisions; `docs/design/`: design notes.

## Commands

- Addon tests: `lua5.1 addons/CoaProbe/tests/run.lua`
- Python tests: `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
- Lab script tests: `bash scripts/tests/coa-client-lab.test.sh` (about 3 minutes, fake gamescope and relay, no server
  needed). A change that touches no script or addon needs no run.
- Syntax check after editing a script: `bash -n scripts/coa-client-lab`, `python3 -m py_compile scripts/<file>.py`

## Rules for this repository

- Conventional Commits. No session trailer and no session URL in commits or PR bodies.
- Code and docs change together in one commit; a lab behaviour change updates the README or the skill and, when it is
  a decision, adds an ADR. User-visible changes go in `CHANGELOG.md` under `Unreleased`.
- Warn before changing the behaviour of `character`, `login`, `probe`, `relay-setup`, `preflight`, `create-instance`
  or `stop`: other agents script them.
- Never leave a non-CoA-class character on a slot: lab characters use classes 12 to 32, and `coa-client-lab erase
  CHARACTER --slot N` deletes a throwaway one even with the lab stopped.
- Claim a slot before use (`coa-slot claim N "note"`), release it afterwards, stop the lab client, and run
  `scripts/coa-worktree-cleanup` once a PR is published. Slot 1 is a dev slot sharing its config with the live
  server: do not edit its config.
- Do not invent commands, options or results: read the script (`--help`, the source) or run the command. Say
  "not verified" for anything not run.

## Pitfalls that cost time

- A `coa-slot` or lab command that restarts the worldserver is only done when the server logs `ready` after the
  restart; `docker logs --since` needs a UTC timestamp ending in `Z`, otherwise it matches old lines.
- `probe eval` takes an expression (it prepends `return`; wrap statements in `(function() ... end)()`), no `|`, under
  255 characters. `eval`, `pksend` and the watches reload the UI; the other probes go through the relay and do not.
- `coa-lab-mem` and `coa-lab-packets` need a slot with `Warden.Enabled = 0` (`coa-slot warden N off`).
- Writing a patch with nested heredocs collapses at the inner terminator: write the patch to a file and apply it.
- `.tele NAME` is ambiguous in the lab chat; use `.go xyz X Y Z MAP O`.
