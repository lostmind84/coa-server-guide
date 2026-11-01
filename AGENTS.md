# AGENTS.md

Guide and tooling for running a CoA (Conquest of Azeroth) server in Docker, plus the parallel-slot and client-lab
scripts agents use to test it. Read this file first. `README.md` is the server install guide (Part 1) and an index of the tooling pages in
`docs/tooling/`: open only the page you need.

## Where to look

| Question | Read |
|---|---|
| Install or run the server from scratch | `QUICKSTART.md`, then README Part 1 (steps 1 to 13) |
| Working on a server: slots, preflight, gameplay tests, cleanup | `skills/coa-slot-workflow/SKILL.md`, `docs/tooling/slots-and-preflight.md`, `scripts/coa-slot help` |
| Is a test result trustworthy? | `docs/tooling/slots-and-preflight.md` (Preflight), `scripts/coa-preflight.py` |
| Driving the game client (`coa-client-lab`, CoaProbe) | `skills/coa-client-check/SKILL.md` and its `references/`; `docs/tooling/client-lab.md`, `docs/tooling/relay-probes.md` |
| Why a lab tool works the way it does | `docs/adr/` (one decision per file, never rewritten) |
| Issue queue workflow | `agents/coa-triage.md`, `agents/git-safety.md` |
| Backups, restore, production | `docs/backup.md`, `docs/restore.md`, `docs/prod-server.md` |
| Was this spell ever obtainable? (outside captures) | `docs/tooling/spell-obtainability.md` (`coa-obtainable`) |
| Faster gameplay verification (optional in-RAM MySQL) | `docs/tooling/ram-mysql.md` |
| Pitfalls that cost time in past runs | `docs/agent-lessons.md` |
| Install the tools and check prerequisites | `scripts/install-agent-tools.sh --check` |

`scripts/coa-client-lab commands` prints every lab command with one example; `--help` prints the full usage.

## Platform

The tooling was written and tested on Linux only: bash scripts driving Docker, `/srv/coa` and `~/CoaServer` paths, a
reflink filesystem (btrfs or xfs), gamescope, xdotool and Wine/Proton. On Windows, macOS or WSL, **adapt the setup so
it works on your OS**: translate paths and commands, replace what does not exist with an equivalent (on Windows the
game client runs natively, so the lab client copy may not be needed at all), and keep going. Tell the user what you
changed, and report as "not verified" any result that rests on an adaptation you could not test.
`scripts/install-agent-tools.sh --check` reports the platform and the missing prerequisites without changing anything.

## Layout

- `scripts/coa-slot`, `coa-client-lab`, `coa-lab-mem`, `coa-lab-packets`, `coa-lab-relay`, `coa-lab-footprint`,
  `coa-preflight.py`, `coa-worktree-cleanup`: the agent tooling (symlink them into `~/.local/bin`).
- `addons/CoaProbe/`: the in-client addon (`Commands.lua`, `Relay.lua`, `Events.lua`) and its tests.
- `skills/`: Claude Code skills (`coa-slot-workflow`, `coa-client-check`, `coa-triage`, `coa-fix-issues-batch`); `agents/`: shared workflows.
- `docs/adr/`: decisions; `docs/design/`: design notes.

## Commands

- Addon tests: `lua5.1 addons/CoaProbe/tests/run.lua`
- Python tests: `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
- Lab script tests: `bash scripts/tests/coa-client-lab.test.sh` (about 3 minutes, fake gamescope and relay, no server
  needed). A change that touches no script or addon needs no run.
- Syntax check after editing a script: `bash -n scripts/coa-client-lab`, `python3 -m py_compile scripts/<file>.py`

## Rules for this repository

- Conventional Commits. No session trailer and no session URL in commits or PR bodies.
- Code and docs change together in one commit; a lab behaviour change updates `docs/tooling/` or the skill and, when it is
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
